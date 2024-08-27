const std = @import("std");
const aws = @import("aws").aws;

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
    region: []const u8,
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
        .region = self.options.region,
    };
    const call = try aws.Request(services.lambda.invoke).call(.{
        .function_name = self.options.name,
        .payload = self.options.payload,
        .log_type = "Tail",
        .invocation_type = "RequestResponse",
    }, options);
    defer call.deinit();
    std.debug.print("{?s}\n", .{call.response.payload});
}
