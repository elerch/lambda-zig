const std = @import("std");

const HandlerFn = *const fn (std.mem.Allocator, []const u8) anyerror![]const u8;

/// Starts the lambda framework. Handler will be called when an event is processing
/// If an allocator is not provided, an approrpriate allocator will be selected and used
pub fn run(allocator: ?std.mem.Allocator, event_handler: HandlerFn) !void { // TODO: remove inferred error set?
    const prefix = "http://";
    const postfix = "/2018-06-01/runtime/invocation";
    const lambda_runtime_uri = std.os.getenv("AWS_LAMBDA_RUNTIME_API").?;
    // TODO: If this is null, go into single use command line mode

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = allocator orelse gpa.allocator();

    const url = try std.fmt.allocPrint(alloc, "{s}{s}{s}/next", .{ prefix, lambda_runtime_uri, postfix });
    defer alloc.free(url);
    const uri = try std.Uri.parse(url);

    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();
    var empty_headers = std.http.Headers.init(alloc);
    defer empty_headers.deinit();
    std.log.info("Bootstrap initializing with event url: {s}", .{url});

    while (true) {
        var req_alloc = std.heap.ArenaAllocator.init(alloc);
        defer req_alloc.deinit();
        const req_allocator = req_alloc.allocator();
        var req = try client.request(.GET, uri, empty_headers, .{});
        defer req.deinit();

        req.start() catch |err| { // Well, at this point all we can do is shout at the void
            std.log.err("Get fail (start): {}", .{err});
            std.os.exit(0);
            continue;
        };

        // Lambda freezes the process at this line of code. During warm start,
        // the process will unfreeze and data will be sent in response to client.get
        req.wait() catch |err| { // Well, at this point all we can do is shout at the void
            std.log.err("Get fail (wait): {}", .{err});
            std.os.exit(0);
            continue;
        };
        if (req.response.status != .ok) {
            // Documentation says something about "exit immediately". The
            // Lambda infrastrucutre restarts, so it's unclear if that's necessary.
            // It seems as though a continue should be fine, and slightly faster
            // std.os.exit(1);
            std.log.err("Get fail: {} {s}", .{
                @intFromEnum(req.response.status),
                req.response.status.phrase() orelse "",
            });
            continue;
        }

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
            if (return_trace) |rt|
                std.log.err("Caught error: {}. Return Trace: {any}", .{ err, rt })
            else
                std.log.err("Caught error: {}. No return trace available", .{err});
            const err_url = try std.fmt.allocPrint(req_allocator, "{s}{s}/runtime/invocation/{s}/error", .{ prefix, lambda_runtime_uri, req_id });
            defer req_allocator.free(err_url);
            const err_uri = try std.Uri.parse(err_url);
            const content =
                \\  {s}
                \\    "errorMessage": "{s}",
                \\    "errorType": "HandlerReturnedError",
                \\    "stackTrace": [ "{any}" ]
                \\  {s}
            ;
            const content_fmt = if (return_trace) |rt|
                try std.fmt.allocPrint(req_allocator, content, .{ "{", @errorName(err), rt, "}" })
            else
                try std.fmt.allocPrint(req_allocator, content, .{ "{", @errorName(err), "no return trace available", "}" });
            defer req_allocator.free(content_fmt);
            std.log.err("Posting to {s}: Data {s}", .{ err_url, content_fmt });

            var err_headers = std.http.Headers.init(req_allocator);
            defer err_headers.deinit();
            err_headers.append(
                "Lambda-Runtime-Function-Error-Type",
                "HandlerReturned",
            ) catch |append_err| {
                std.log.err("Error appending error header to post response for request id {s}: {}", .{ req_id, append_err });
                std.os.exit(0);
                continue;
            };
            var err_req = try client.request(.POST, err_uri, empty_headers, .{});
            defer err_req.deinit();
            err_req.start() catch |post_err| { // Well, at this point all we can do is shout at the void
                std.log.err("Error posting response for request id {s}: {}", .{ req_id, post_err });
                std.os.exit(0);
                continue;
            };

            err_req.wait() catch |post_err| { // Well, at this point all we can do is shout at the void
                std.log.err("Error posting response for request id {s}: {}", .{ req_id, post_err });
                std.os.exit(0);
                continue;
            };
            // TODO: Determine why this post is not returning
            if (err_req.response.status != .ok) {
                // Documentation says something about "exit immediately". The
                // Lambda infrastrucutre restarts, so it's unclear if that's necessary.
                // It seems as though a continue should be fine, and slightly faster
                // std.os.exit(1);
                std.log.err("Get fail: {} {s}", .{
                    @intFromEnum(err_req.response.status),
                    err_req.response.status.phrase() orelse "",
                });
                continue;
            }
            std.log.err("Post complete", .{});
            continue;
        };
        // TODO: We should catch these potential alloc errors too
        // TODO: This whole loop should be in another function so we can catch everything at once
        const response_url = try std.fmt.allocPrint(req_allocator, "{s}{s}{s}/{s}/response", .{ prefix, lambda_runtime_uri, postfix, req_id });
        defer allocator.free(response_url);
        const response_uri = try std.Uri.parse(response_url);
        const response_content = try std.fmt.allocPrint(req_allocator, "{s} \"content\": \"{s}\" {s}", .{ "{", event_response, "}" });
        var resp_req = try client.request(.POST, response_uri, empty_headers, .{});
        defer resp_req.deinit();
        try resp_req.start();
        try resp_req.writeAll(response_content); // TODO: AllocPrint + writeAll makes no sense
        resp_req.wait() catch |err| {
            // TODO: report error
            std.log.err("Error posting response for request id {s}: {}", .{ req_id, err });
            continue;
        };
    }
}
