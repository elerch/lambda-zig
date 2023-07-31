const std = @import("std");
const zfetch = @import("zfetch");

pub fn run(event_handler: fn (std.mem.Allocator, []const u8) anyerror![]const u8) !void { // TODO: remove inferred error set?
    const prefix = "http://";
    const postfix = "/2018-06-01/runtime/invocation";
    const lambda_runtime_uri = std.os.getenv("AWS_LAMBDA_RUNTIME_API");

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const url = try std.fmt.allocPrint(allocator, "{s}{s}{s}/next", .{ prefix, lambda_runtime_uri, postfix });
    defer allocator.free(url);

    try zfetch.init();
    defer zfetch.deinit();
    std.log.info("Bootstrap initializing with event url: {s}", .{url});

    var headers = zfetch.Headers.init(allocator);
    defer headers.deinit();
    while (true) {
        var req_alloc = std.heap.ArenaAllocator.init(allocator);
        defer req_alloc.deinit();
        const req_allocator = req_alloc.allocator();
        var req = try zfetch.Request.init(req_allocator, url, null);
        defer req.deinit();

        // Lambda freezes the process at this line of code. During warm start,
        // the process will unfreeze and data will be sent in response to client.get
        req.do(.GET, headers, null) catch |err| {
            std.log.err("Get fail: {}", .{err});
            // Documentation says something about "exit immediately". The
            // Lambda infrastrucutre restarts, so it's unclear if that's necessary.
            // It seems as though a continue should be fine, and slightly faster
            // std.os.exit(1);
            continue;
        };

        var request_id: ?[]const u8 = null;
        var content_length: ?usize = null;
        for (req.headers.list.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Lambda-Runtime-Aws-Request-Id"))
                request_id = h.value;
            if (std.ascii.eqlIgnoreCase(h.name, "Content-Length")) {
                content_length = std.fmt.parseUnsigned(usize, h.value, 10) catch null;
                if (content_length == null)
                    std.log.warn("Error parsing content length value: '{s}'", .{h.value});
            }
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

        const reader = req.reader();
        var buf: [65535]u8 = undefined;

        var resp_payload = std.ArrayList(u8).init(req_allocator);
        if (content_length) |len| {
            resp_payload.ensureTotalCapacity(len) catch {
                std.log.err("Could not allocate memory for body of request id: {s}", .{request_id.?});
                continue;
            };
        }

        defer resp_payload.deinit();

        while (true) {
            const read = try reader.read(&buf);
            try resp_payload.appendSlice(buf[0..read]);
            if (read == 0) break;
        }
        const event_response = event_handler(req_allocator, resp_payload.items) catch |err| {
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

            var err_req = try zfetch.Request.init(req_allocator, err_url, null);
            defer err_req.deinit();
            var err_headers = zfetch.Headers.init(req_allocator);
            defer err_headers.deinit();
            err_headers.append(.{
                .name = "Lambda-Runtime-Function-Error-Type",
                .value = "HandlerReturned",
            }) catch |append_err| {
                std.log.err("Error appending error header to post response for request id {s}: {}", .{ req_id, append_err });
                std.os.exit(0);
                continue;
            };
            // TODO: Determine why this post is not returning
            err_req.do(.POST, err_headers, content_fmt) catch |post_err| { // Well, at this point all we can do is shout at the void
                std.log.err("Error posting response for request id {s}: {}", .{ req_id, post_err });
                std.os.exit(0);
                continue;
            };
            std.log.err("Post complete", .{});
            continue;
        };
        // We should catch these potential alloc errors too
        const response_url = try std.fmt.allocPrint(req_allocator, "{s}{s}{s}/{s}/response", .{ prefix, lambda_runtime_uri, postfix, req_id });
        const response_content = try std.fmt.allocPrint(req_allocator, "{s} \"content\": \"{s}\" {s}", .{ "{", event_response, "}" });
        var resp_req = try zfetch.Request.init(req_allocator, response_url, null);
        defer resp_req.deinit();
        resp_req.do(.POST, headers, response_content) catch |err| {
            // TODO: report error
            std.log.err("Error posting response for request id {s}: {}", .{ req_id, err });
            continue;
        };
    }
}
