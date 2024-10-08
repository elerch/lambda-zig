const std = @import("std");
const Region = @import("Region.zig");
const aws = @import("aws").aws;

const Deploy = @This();

step: std.Build.Step,
options: Options,

const base_id: std.Build.Step.Id = .custom;

pub const Options = struct {
    /// Function name to be used for the function
    name: []const u8,

    /// Architecture for Lambda function
    arch: std.Target.Cpu.Arch,

    /// Iam step. This will be a dependency of the deployment
    iam_step: *@import("Iam.zig"),

    /// Packaging step. This will be a dependency of the deployment
    package_step: *@import("Package.zig"),

    /// Region for deployment
    region: *Region,
};

pub fn create(owner: *std.Build, options: Options) *Deploy {
    const name = owner.dupe(options.name);
    const step_name = owner.fmt("{s} {s}{s}", .{
        "aws lambda",
        "deploy ",
        name,
    });
    const self = owner.allocator.create(Deploy) catch @panic("OOM");
    self.* = .{
        .step = std.Build.Step.init(.{
            .id = base_id,
            .name = step_name,
            .owner = owner,
            .makeFn = make,
        }),
        .options = options,
    };

    self.step.dependOn(&options.iam_step.step);
    self.step.dependOn(&options.package_step.step);
    return self;
}

/// gets the last time we deployed this function from the name in cache.
/// If not in cache, null is returned. Note that cache is not account specific,
/// so if you're banging around multiple accounts, you'll want to use different
/// local zig caches for each
fn getlastDeployedTime(step: *std.Build.Step, name: []const u8) !?[]const u8 {
    try step.owner.cache_root.handle.makePath("iam");
    // we should be able to use the role name, as only the following characters
    // are allowed: _+=,.@-.
    const cache_file = try std.fmt.allocPrint(
        step.owner.allocator,
        "deploy{s}{s}",
        .{ std.fs.path.sep_str, name },
    );
    const buff = try step.owner.allocator.alloc(u8, 64);
    const time = step.owner.cache_root.handle.readFile(cache_file, buff) catch return null;
    return time;
}

fn make(step: *std.Build.Step, node: std.Progress.Node) anyerror!void {
    _ = node;
    const self: *Deploy = @fieldParentPtr("step", step);

    if (self.options.arch != .aarch64 and self.options.arch != .x86_64)
        return step.fail("AWS Lambda can only deploy aarch64 and x86_64 functions ({} not allowed)", .{self.options.arch});

    const last_packaged_sha256 = blk: {
        // file should always be there, but we shouldn't break if the cache doesn't exist
        const last_deployed_id_file = std.fs.openFileAbsolute(try self.options.package_step.shasumFilePath(), .{}) catch break :blk null;
        defer last_deployed_id_file.close();
        break :blk try last_deployed_id_file.readToEndAlloc(step.owner.allocator, 2048);
    };

    var client = aws.Client.init(self.step.owner.allocator, .{});
    defer client.deinit();
    const services = aws.Services(.{.lambda}){};
    const function = blk: {
        var diagnostics = aws.Diagnostics{
            .http_code = undefined,
            .response_body = undefined,
            .allocator = self.step.owner.allocator,
        };
        const options = aws.Options{
            .client = client,
            .diagnostics = &diagnostics,
            .region = try self.options.region.region(),
        };

        aws.globalLogControl(.info, .warn, .info, true);
        defer aws.globalLogControl(.info, .warn, .info, false);
        const call = aws.Request(services.lambda.get_function).call(.{
            .function_name = self.options.name,
        }, options) catch |e| {
            // There seems an issue here, but realistically, we have an arena
            // so there's no leak leaving this out
            defer diagnostics.deinit();
            if (diagnostics.http_code == 404) break :blk null;
            return step.fail(
                "Unknown error {} from Lambda GetFunction. HTTP code {}, message: {s}",
                .{ e, diagnostics.http_code, diagnostics.response_body },
            );
        };
        defer call.deinit();

        break :blk .{
            .last_modified = try step.owner.allocator.dupe(u8, call.response.configuration.?.last_modified.?),
            .revision_id = try step.owner.allocator.dupe(u8, call.response.configuration.?.revision_id.?),
            .sha256 = try step.owner.allocator.dupe(u8, call.response.configuration.?.code_sha256.?),
        };
    };

    if (last_packaged_sha256) |s|
        if (function) |f|
            if (std.mem.eql(u8, s, f.sha256)) {
                step.result_cached = true;
                return;
            };

    const encoder = std.base64.standard.Encoder;
    const file = try std.fs.openFileAbsolute(self.options.package_step.packagedFileLazyPath().getPath2(step.owner, step), .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(step.owner.allocator, 100 * 1024 * 1024);
    const base64_buf = try step.owner.allocator.alloc(u8, encoder.calcSize(bytes.len));
    const base64_bytes = encoder.encode(base64_buf, bytes);
    const options = aws.Options{
        .client = client,
        .region = try self.options.region.region(),
    };
    const arm64_arch = [_][]const u8{"arm64"};
    const x86_64_arch = [_][]const u8{"x86_64"};
    const architectures = (if (self.options.arch == .aarch64) arm64_arch else x86_64_arch);
    const arches: [][]const u8 = @constCast(architectures[0..]);
    if (function) |f| {
        // TODO: make sure our zipfile newer than the lambda function
        const update_call = try aws.Request(services.lambda.update_function_code).call(.{
            .function_name = self.options.name,
            .architectures = arches,
            .revision_id = f.revision_id,
            .zip_file = base64_bytes,
        }, options);
        defer update_call.deinit();
    } else {
        // New function - we need to create from scratch
        const create_call = try aws.Request(services.lambda.create_function).call(.{
            .function_name = self.options.name,
            .architectures = arches,
            .code = .{ .zip_file = base64_bytes },
            .handler = "not_applicable",
            .package_type = "Zip",
            .runtime = "provided.al2",
            .role = self.options.iam_step.resolved_arn,
        }, options);
        defer create_call.deinit();
    }
}
