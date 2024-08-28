const std = @import("std");
const aws = @import("aws").aws;
const Region = @import("Region.zig");
const Invoke = @This();

step: std.Build.Step,
options: Options,

const base_id: std.Build.Step.Id = .custom;

pub const Options = struct {
    /// Function name to invoke
    name: []const u8,

    /// Payload to send to the function
    payload: []const u8,

    /// Region for deployment
    region: *Region,
};

pub fn create(owner: *std.Build, options: Options) *Invoke {
    const name = owner.dupe(options.name);
    const step_name = owner.fmt("{s} {s}{s}", .{
        "aws lambda",
        "invoke",
        name,
    });
    const self = owner.allocator.create(Invoke) catch @panic("OOM");
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

fn make(step: *std.Build.Step, node: std.Progress.Node) anyerror!void {
    _ = node;
    const self: *Invoke = @fieldParentPtr("step", step);

    var client = aws.Client.init(self.step.owner.allocator, .{});
    defer client.deinit();
    const services = aws.Services(.{.lambda}){};

    const options = aws.Options{
        .client = client,
        .region = try self.options.region.region(),
    };
    var inx: usize = 10; // 200ms * 10
    while (inx > 0) : (inx -= 1) {
        var diagnostics = aws.Diagnostics{
            .http_code = undefined,
            .response_body = undefined,
            .allocator = self.step.owner.allocator,
        };
        const call = aws.Request(services.lambda.get_function).call(.{
            .function_name = self.options.name,
        }, options) catch |e| {
            // There seems an issue here, but realistically, we have an arena
            // so there's no leak leaving this out
            defer diagnostics.deinit();
            if (diagnostics.http_code == 404) continue; // function was just created...it's ok
            return step.fail(
                "Unknown error {} from Lambda GetFunction. HTTP code {}, message: {s}",
                .{ e, diagnostics.http_code, diagnostics.response_body },
            );
        };
        defer call.deinit();
        if (!std.mem.eql(u8, "InProgress", call.response.configuration.?.last_update_status.?))
            break; // We're ready to invoke!
        const ms: usize = if (inx == 5) 500 else 50;
        std.time.sleep(ms * std.time.ns_per_ms);
    }
    if (inx == 0)
        return step.fail("Timed out waiting for lambda to update function", .{});
    const call = try aws.Request(services.lambda.invoke).call(.{
        .function_name = self.options.name,
        .payload = self.options.payload,
        .log_type = "Tail",
        .invocation_type = "RequestResponse",
    }, options);
    defer call.deinit();
    std.debug.print("{?s}\n", .{call.response.payload});
}
