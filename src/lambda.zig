const std = @import("std");
const builtin = @import("builtin");

const HandlerFn = *const fn (std.mem.Allocator, []const u8) anyerror![]const u8;

const log = std.log.scoped(.lambda);

/// Starts the lambda framework. Handler will be called when an event is processing
/// If an allocator is not provided, an approrpriate allocator will be selected and used
pub fn run(allocator: ?std.mem.Allocator, event_handler: HandlerFn) !void { // TODO: remove inferred error set?
    const prefix = "http://";
    const postfix = "/2018-06-01/runtime/invocation";
    const lambda_runtime_uri = std.os.getenv("AWS_LAMBDA_RUNTIME_API") orelse test_lambda_runtime_uri.?;
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
    log.info("tid {d} (lambda): Bootstrap initializing with event url: {s}", .{ std.Thread.getCurrentId(), url });

    while (lambda_remaining_requests == null or lambda_remaining_requests.? > 0) {
        if (lambda_remaining_requests) |*r| {
            // we're under test
            log.debug("lambda remaining requests: {d}", .{r.*});
            r.* -= 1;
        }
        var req_alloc = std.heap.ArenaAllocator.init(alloc);
        defer req_alloc.deinit();
        const req_allocator = req_alloc.allocator();
        var req = try client.request(.GET, uri, empty_headers, .{});
        defer req.deinit();

        req.start() catch |err| { // Well, at this point all we can do is shout at the void
            log.err("Get fail (start): {}", .{err});
            std.os.exit(0);
            continue;
        };

        // Lambda freezes the process at this line of code. During warm start,
        // the process will unfreeze and data will be sent in response to client.get
        req.wait() catch |err| { // Well, at this point all we can do is shout at the void
            log.err("Get fail (wait): {}", .{err});
            std.os.exit(0);
            continue;
        };
        if (req.response.status != .ok) {
            // Documentation says something about "exit immediately". The
            // Lambda infrastrucutre restarts, so it's unclear if that's necessary.
            // It seems as though a continue should be fine, and slightly faster
            // std.os.exit(1);
            log.err("Get fail: {} {s}", .{
                @intFromEnum(req.response.status),
                req.response.status.phrase() orelse "",
            });
            continue;
        }

        var request_id: ?[]const u8 = null;
        var content_length: ?usize = null;
        for (req.response.headers.list.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Lambda-Runtime-Aws-Request-Id"))
                request_id = h.value;
            if (std.ascii.eqlIgnoreCase(h.name, "Content-Length")) {
                content_length = std.fmt.parseUnsigned(usize, h.value, 10) catch null;
                if (content_length == null)
                    log.warn("Error parsing content length value: '{s}'", .{h.value});
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
            log.err("Could not find request id: skipping request", .{});
            continue;
        }
        const req_id = request_id.?;
        log.debug("got lambda request with id {s}", .{req_id});

        const reader = req.reader();
        var buf: [65535]u8 = undefined;

        var resp_payload = std.ArrayList(u8).init(req_allocator);
        if (content_length) |len| {
            resp_payload.ensureTotalCapacity(len) catch {
                log.err("Could not allocate memory for body of request id: {s}", .{request_id.?});
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
                log.err("Caught error: {}. Return Trace: {any}", .{ err, rt })
            else
                log.err("Caught error: {}. No return trace available", .{err});
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
            log.err("Posting to {s}: Data {s}", .{ err_url, content_fmt });

            var err_headers = std.http.Headers.init(req_allocator);
            defer err_headers.deinit();
            err_headers.append(
                "Lambda-Runtime-Function-Error-Type",
                "HandlerReturned",
            ) catch |append_err| {
                log.err("Error appending error header to post response for request id {s}: {}", .{ req_id, append_err });
                std.os.exit(0);
                continue;
            };
            var err_req = try client.request(.POST, err_uri, empty_headers, .{});
            defer err_req.deinit();
            err_req.start() catch |post_err| { // Well, at this point all we can do is shout at the void
                log.err("Error posting response for request id {s}: {}", .{ req_id, post_err });
                std.os.exit(0);
                continue;
            };

            err_req.wait() catch |post_err| { // Well, at this point all we can do is shout at the void
                log.err("Error posting response for request id {s}: {}", .{ req_id, post_err });
                std.os.exit(0);
                continue;
            };
            // TODO: Determine why this post is not returning
            if (err_req.response.status != .ok) {
                // Documentation says something about "exit immediately". The
                // Lambda infrastrucutre restarts, so it's unclear if that's necessary.
                // It seems as though a continue should be fine, and slightly faster
                // std.os.exit(1);
                log.err("Get fail: {} {s}", .{
                    @intFromEnum(err_req.response.status),
                    err_req.response.status.phrase() orelse "",
                });
                continue;
            }
            log.err("Post complete", .{});
            continue;
        };
        // TODO: We should catch these potential alloc errors too
        // TODO: This whole loop should be in another function so we can catch everything at once
        const response_url = try std.fmt.allocPrint(req_allocator, "{s}{s}{s}/{s}/response", .{ prefix, lambda_runtime_uri, postfix, req_id });
        defer req_allocator.free(response_url);
        const response_uri = try std.Uri.parse(response_url);
        const response_content = try std.fmt.allocPrint(req_allocator, "{s} \"content\": \"{s}\" {s}", .{ "{", event_response, "}" });
        var resp_req = try client.request(.POST, response_uri, empty_headers, .{});
        defer resp_req.deinit();
        resp_req.transfer_encoding = .{ .content_length = response_content.len };
        try resp_req.start();
        try resp_req.writeAll(response_content); // TODO: AllocPrint + writeAll makes no sense
        try resp_req.finish();
        resp_req.wait() catch |err| {
            // TODO: report error
            log.err("Error posting response for request id {s}: {}", .{ req_id, err });
            continue;
        };
    }
}

////////////////////////////////////////////////////////////////////////
// All code below this line is for testing
////////////////////////////////////////////////////////////////////////
var server_port: ?u16 = null;
var server_remaining_requests: usize = 0;
var lambda_remaining_requests: ?usize = null;
var server_response: []const u8 = "unset";
var server_request_aka_lambda_response: []u8 = "";
var test_lambda_runtime_uri: ?[]u8 = null;

var server_ready = false;
/// This starts a test server. We're not testing the server itself,
/// so the main tests will start this thing up and create an arena around the
/// whole thing so we can just deallocate everything at once at the end,
/// leaks be damned
fn startServer(allocator: std.mem.Allocator) !std.Thread {
    return try std.Thread.spawn(
        .{},
        threadMain,
        .{allocator},
    );
}

fn threadMain(allocator: std.mem.Allocator) !void {
    var server = std.http.Server.init(allocator, .{ .reuse_address = true });
    // defer server.deinit();

    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    try server.listen(address);
    server_port = server.socket.listen_address.in.getPort();

    test_lambda_runtime_uri = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{server_port.?});
    log.debug("server listening at {s}", .{test_lambda_runtime_uri.?});
    defer server.deinit();
    defer test_lambda_runtime_uri = null;
    defer server_port = null;
    log.info("starting server thread, tid {d}", .{std.Thread.getCurrentId()});
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var aa = arena.allocator();
    // We're in control of all requests/responses, so this flag will tell us
    // when it's time to shut down
    while (server_remaining_requests > 0) {
        server_remaining_requests -= 1;
        // defer {
        //     if (!arena.reset(.{ .retain_capacity = {} })) {
        //         // reallocation failed, arena is degraded
        //         log.warn("Arena reset failed and is degraded. Resetting arena", .{});
        //         arena.deinit();
        //         arena = std.heap.ArenaAllocator.init(allocator);
        //         aa = arena.allocator();
        //     }
        // }

        processRequest(aa, &server) catch |e| {
            log.err("Unexpected error processing request: {any}", .{e});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
        };
    }
}

fn processRequest(allocator: std.mem.Allocator, server: *std.http.Server) !void {
    server_ready = true;
    errdefer server_ready = false;
    log.debug(
        "tid {d} (server): server waiting to accept. requests remaining: {d}",
        .{ std.Thread.getCurrentId(), server_remaining_requests + 1 },
    );
    var res = try server.accept(.{ .allocator = allocator });
    server_ready = false;
    defer res.deinit();
    defer _ = res.reset();
    try res.wait(); // wait for client to send a complete request head

    const errstr = "Internal Server Error\n";
    var errbuf: [errstr.len]u8 = undefined;
    @memcpy(&errbuf, errstr);
    var response_bytes: []const u8 = errbuf[0..];

    if (res.request.content_length) |l|
        server_request_aka_lambda_response = try res.reader().readAllAlloc(allocator, @as(usize, l));

    log.debug(
        "tid {d} (server): {d} bytes read from request",
        .{ std.Thread.getCurrentId(), server_request_aka_lambda_response.len },
    );

    // try response.headers.append("content-type", "text/plain");
    response_bytes = serve(allocator, &res) catch |e| brk: {
        res.status = .internal_server_error;
        // TODO: more about this particular request
        log.err("Unexpected error from executor processing request: {any}", .{e});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        break :brk "Unexpected error generating request to lambda";
    };
    res.transfer_encoding = .{ .content_length = response_bytes.len };
    try res.do();
    _ = try res.writer().writeAll(response_bytes);
    try res.finish();
    log.debug(
        "tid {d} (server): sent response",
        .{std.Thread.getCurrentId()},
    );
}

fn serve(allocator: std.mem.Allocator, res: *std.http.Server.Response) ![]const u8 {
    _ = allocator;
    // try res.headers.append("content-length", try std.fmt.allocPrint(allocator, "{d}", .{server_response.len}));
    try res.headers.append("Lambda-Runtime-Aws-Request-Id", "69");
    return server_response;
}

fn handler(allocator: std.mem.Allocator, event_data: []const u8) ![]const u8 {
    _ = allocator;
    return event_data;
}
fn test_run(allocator: std.mem.Allocator, event_handler: HandlerFn) !std.Thread {
    return try std.Thread.spawn(
        .{},
        run,
        .{ allocator, event_handler },
    );
}

fn lambda_request(allocator: std.mem.Allocator, request: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var aa = arena.allocator();
    // Setup our server to run, and set the response for the server to the
    // request. There is a cognitive disconnect here between mental model and
    // physical model.
    //
    // Mental model:
    //
    // Lambda request -> λ -> Lambda response
    //
    // Physcial Model:
    //
    // 1. λ requests instructions from server
    // 2. server provides "Lambda request"
    // 3. λ posts response back to server
    //
    // So here we are setting up our server, then our lambda request loop,
    // but it all needs to be in seperate threads so we can control startup
    // and shut down. Both server and Lambda are set up to watch global variable
    // booleans to know when to shut down. This function is designed for a
    // single request/response pair only

    server_remaining_requests = 2; // Tell our server to run for just two requests
    server_response = request; // set our instructions to lambda, which in our
    // physical model above, is the server response
    defer server_response = "unset"; // set it back so we don't get confused later
    // when subsequent tests fail
    const server_thread = try startServer(aa); // start the server, get it ready
    while (!server_ready)
        std.time.sleep(100);

    log.debug("tid {d} (main): server reports ready", .{std.Thread.getCurrentId()});
    // we aren't testing the server,
    // so we'll use the arena allocator
    defer server_thread.join(); // we'll be shutting everything down before we exit

    // Now we need to start the lambda framework, following a siimilar pattern
    lambda_remaining_requests = 1; // in case anyone messed with this, we will make sure we start
    const lambda_thread = try test_run(allocator, handler); // We want our function under test to report leaks
    lambda_thread.join();
    return server_request_aka_lambda_response;
}

test "basic request" {
    // std.testing.log_level = .debug;
    const allocator = std.testing.allocator;
    const request =
        \\{"foo": "bar", "baz": "qux"}
    ;
    const lambda_response = try lambda_request(allocator, request);
    try std.testing.expectEqualStrings(lambda_response, request);
}
