const std = @import("std");
const requestz = @import("requestz");

pub fn run(event_handler: fn (*std.mem.Allocator, []const u8) anyerror![]const u8) !void { // TODO: remove inferred error set?
    const prefix = "http://";
    const postfix = "/2018-06-01/runtime/invocation";
    const lambda_runtime_uri = std.os.getenv("AWS_LAMBDA_RUNTIME_API");

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;

    const url = try std.fmt.allocPrint(allocator, "{s}{s}{s}/next", .{ prefix, lambda_runtime_uri, postfix });
    defer allocator.free(url);

    std.log.info("Event Url: {s}", .{url});

    while (true) {
        var req_alloc = std.heap.ArenaAllocator.init(allocator);
        defer req_alloc.deinit();
        const req_allocator = &req_alloc.allocator;
        var client = try requestz.Client.init(req_allocator);
        // defer client.deinit();
        var response = client.get(url, .{}) catch |err| {
            // TODO: report error
            std.log.err("Get fail: {}", .{err});
            continue;
        };
        defer response.deinit();

        var request_id: ?[]const u8 = null;
        for (response.headers.items()) |h| {
            if (std.mem.indexOf(u8, h.name.value, "Lambda-Runtime-Aws-Request-Id")) |_|
                request_id = h.value;
        }
        if (request_id == null) {
            // TODO: report error
            std.log.err("Could not find request id: skipping request", .{});
            continue;
        }
        const req_id = request_id.?;

        const event_response = event_handler(req_allocator, response.body) catch |err| {
            // TODO: report error
            std.log.err("Error posting response for request id {s}: {}", .{ req_id, err });
            continue;
        };
        const response_url = try std.fmt.allocPrint(req_allocator, "{s}{s}{s}/{s}/response", .{ prefix, lambda_runtime_uri, postfix, req_id });
        // defer req_allocator.free(response_url);
        var resp_resp = client.post(response_url, .{ .content = event_response }) catch |err| {
            // TODO: report error
            std.log.err("Error posting response for request id {s}: {}", .{ req_id, err });
            continue;
        };
        defer resp_resp.deinit();
    }
}
