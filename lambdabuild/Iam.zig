const std = @import("std");
const aws = @import("aws").aws;

const Iam = @This();

step: std.Build.Step,
options: Options,
/// resolved_arn will be set only after make is run
resolved_arn: []const u8 = undefined,

arn_buf: [2048]u8 = undefined, // https://docs.aws.amazon.com/IAM/latest/APIReference/API_Role.html has 2k limit
const base_id: std.Build.Step.Id = .custom;

pub const Options = struct {
    name: []const u8 = "",
    role_name: []const u8,
    role_arn: ?[]const u8,
};

pub fn create(owner: *std.Build, options: Options) *Iam {
    const name = owner.dupe(options.name);
    const step_name = owner.fmt("{s} {s}{s}", .{
        "aws lambda",
        "iam",
        name,
    });
    const self = owner.allocator.create(Iam) catch @panic("OOM");
    self.* = .{
        .step = std.Build.Step.init(.{
            .id = base_id,
            .name = step_name,
            .owner = owner,
            .makeFn = make,
        }),
        .options = options,
    };

    return self;
}

/// gets an IamArn from the name in cache. If not in cache, null is returned
/// Note that cache is not account specific, so if you're banging around multiple
/// accounts, you'll want to use different local zig caches for each
pub fn getIamArnFromName(step: *std.Build.Step, name: []const u8) !?[]const u8 {
    try step.owner.cache_root.handle.makePath("iam");
    // we should be able to use the role name, as only the following characters
    // are allowed: _+=,.@-.
    const iam_file = try std.fmt.allocPrint(
        step.owner.allocator,
        "iam{s}{s}",
        .{ std.fs.path.sep_str, name },
    );
    const buff = try step.owner.allocator.alloc(u8, 64);
    const arn = step.owner.cache_root.handle.readFile(iam_file, buff) catch return null;
    return arn;
}

fn make(step: *std.Build.Step, node: std.Progress.Node) anyerror!void {
    _ = node;
    const self: *Iam = @fieldParentPtr("step", step);

    if (try getIamArnFromName(step, self.options.role_name)) |a| {
        step.result_cached = true;
        @memcpy(self.arn_buf[0..a.len], a);
        self.resolved_arn = self.arn_buf[0..a.len];
        return; // exists in cache - nothing to do
    }

    var client = aws.Client.init(self.step.owner.allocator, .{});
    defer client.deinit();
    const services = aws.Services(.{.iam}){};

    var arn = blk: {
        var diagnostics = aws.Diagnostics{
            .http_code = undefined,
            .response_body = undefined,
            .allocator = self.step.owner.allocator,
        };
        const options = aws.Options{
            .client = client,
            .diagnostics = &diagnostics,
        };

        const call = aws.Request(services.iam.get_role).call(.{
            .role_name = self.options.role_name, // TODO: if we have a role_arn, we should use it and skip
        }, options) catch |e| {
            defer diagnostics.deinit();
            if (diagnostics.http_code == 404) break :blk null;
            return step.fail(
                "Unknown error {} from IAM GetRole. HTTP code {}, message: {s}",
                .{ e, diagnostics.http_code, diagnostics.response_body },
            );
        };
        defer call.deinit();

        break :blk try step.owner.allocator.dupe(u8, call.response.role.arn);
    };
    // Now ARN will either be null (does not exist), or a value

    if (arn == null) {
        // we need to create the role before proceeding
        const options = aws.Options{
            .client = client,
        };

        const create_call = try aws.Request(services.iam.create_role).call(.{
            .role_name = self.options.role_name,
            .assume_role_policy_document =
            \\{
            \\  "Version": "2012-10-17",
            \\  "Statement": [
            \\    {
            \\      "Sid": "",
            \\      "Effect": "Allow",
            \\      "Principal": {
            \\        "Service": "lambda.amazonaws.com"
            \\      },
            \\      "Action": "sts:AssumeRole"
            \\    }
            \\  ]
            \\}
            ,
        }, options);
        defer create_call.deinit();
        arn = try step.owner.allocator.dupe(u8, create_call.response.role.arn);
        const attach_call = try aws.Request(services.iam.attach_role_policy).call(.{
            .policy_arn = "arn:aws:iam::aws:policy/AWSLambdaExecute",
            .role_name = self.options.role_name,
        }, options);
        defer attach_call.deinit();
    }

    @memcpy(self.arn_buf[0..arn.?.len], arn.?);
    self.resolved_arn = self.arn_buf[0..arn.?.len];

    // NOTE: This must match getIamArnFromName
    const iam_file = try std.fmt.allocPrint(
        step.owner.allocator,
        "iam{s}{s}",
        .{ std.fs.path.sep_str, self.options.role_name },
    );
    try step.owner.cache_root.handle.writeFile(.{
        .sub_path = iam_file,
        .data = arn.?,
    });
}
