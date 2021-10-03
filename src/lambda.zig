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

    std.log.notice("Bootstrap initializing with event url: {s}", .{url});

    while (true) {
        var req_alloc = std.heap.ArenaAllocator.init(allocator);
        defer req_alloc.deinit();
        const req_allocator = &req_alloc.allocator;
        var client = try requestz.Client.init(req_allocator);
        // defer client.deinit();
        // Lambda freezes the process at this line of code. During warm start,
        // the process will unfreeze and data will be sent in response to client.get
        var response = client.get(url, .{}) catch |err| {
            std.log.err("Get fail: {}", .{err});
            // Documentation says something about "exit immediately". The
            // Lambda infrastrucutre restarts, so it's unclear if that's necessary.
            // It seems as though a continue should be fine, and slightly faster
            // std.os.exit(1);
            continue;
        };
        defer response.deinit();

        var request_id: ?[]const u8 = null;
        for (response.headers.items()) |h| {
            if (std.mem.indexOf(u8, h.name.value, "Lambda-Runtime-Aws-Request-Id")) |_|
                request_id = h.value;
            // TODO: XRay uses an environment variable to do its magic. It's our
            //       responsibility to set this, but no zig-native setenv(3)/putenv(3)
            //       exists. I would kind of rather not link in libc for this,
            //       so we'll hold for now and think on this
            //        if (std.mem.indexOf(u8, h.name.value, "Lambda-Runtime-Trace-Id")) |_|
            //            std.process.
            // std.os.setenv("AWS_LAMBDA_RUNTIME_API");
        }
        if (request_id == null) {
            // We can't report back an issue because the runtime error reporting endpoint
            // uses request id in its path. So the best we can do is log the error and move
            // on here.
            std.log.err("Could not find request id: skipping request", .{});
            continue;
        }
        const req_id = request_id.?;

        const event_response = event_handler(req_allocator, response.body) catch |err| {
            // Stack trace will return null if stripped
            const return_trace = @errorReturnTrace();
            std.log.err("Caught error: {}. Return Trace: {}", .{ err, return_trace });
            const err_url = try std.fmt.allocPrint(req_allocator, "{s}{s}/runtime/invocation/{s}/error", .{ prefix, lambda_runtime_uri, req_id });
            defer req_allocator.free(err_url);
            const content =
                \\  {s}
                \\    "errorMessage": "{s}",
                \\    "errorType": "HandlerReturnedError",
                \\    "stackTrace": [ "{}" ]
                \\  {s}
            ;
            const content_fmt = try std.fmt.allocPrint(req_allocator, content, .{ "{", @errorName(err), return_trace, "}" });
            defer req_allocator.free(content_fmt);
            std.log.err("Posting to {s}: Data {s}", .{ err_url, content_fmt });
            var headers = .{.{ "Lambda-Runtime-Function-Error-Type", "HandlerReturned" }};
            // TODO: Determine why this post is not returning
            var err_resp = client.post(err_url, .{
                .content = content_fmt,
                .headers = headers,
            }) catch |post_err| { // Well, at this point all we can do is shout at the void
                std.log.err("Error posting response for request id {s}: {}", .{ req_id, post_err });
                std.os.exit(0);
                continue;
            };
            std.log.err("Post complete", .{});
            defer err_resp.deinit();
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
