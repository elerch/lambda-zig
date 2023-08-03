const std = @import("std");
const builtin = @import("builtin");

const HandlerFn = *const fn (std.mem.Allocator, []const u8) anyerror![]const u8;

const log = std.log.scoped(.lambda);

var empty_headers: std.http.Headers = undefined;
var client: ?std.http.Client = null;

const prefix = "http://";
const postfix = "/2018-06-01/runtime/invocation";

pub fn deinit() void {
    if (client) |*c| c.deinit();
    client = null;
}
/// Starts the lambda framework. Handler will be called when an event is processing
/// If an allocator is not provided, an approrpriate allocator will be selected and used
/// This function is intended to loop infinitely. If not used in this manner,
/// make sure to call the deinit() function
pub fn run(allocator: ?std.mem.Allocator, event_handler: HandlerFn) !void { // TODO: remove inferred error set?
    const lambda_runtime_uri = std.os.getenv("AWS_LAMBDA_RUNTIME_API") orelse test_lambda_runtime_uri.?;
    // TODO: If this is null, go into single use command line mode

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = allocator orelse gpa.allocator();

    const url = try std.fmt.allocPrint(alloc, "{s}{s}{s}/next", .{ prefix, lambda_runtime_uri, postfix });
    defer alloc.free(url);
    const uri = try std.Uri.parse(url);

    // TODO: Simply adding this line without even using the client is enough
    // to cause seg faults!?
    // client = client orelse .{ .allocator = alloc };
    // so we'll do this instead
    if (client != null) return error.MustDeInitBeforeCallingRunAgain;
    client = .{ .allocator = alloc };
    empty_headers = std.http.Headers.init(alloc);
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

        // Fundamentally we're doing 3 things:
        // 1. Get the next event from Lambda (event data and request id)
        // 2. Call our handler to get the response
        // 3. Post the response back to Lambda
        var ev = getEvent(req_allocator, uri) catch |err| {
            // Well, at this point all we can do is shout at the void
            log.err("Error fetching event details: {}", .{err});
            std.os.exit(1);
            // continue;
        };
        if (ev == null) continue; // this gets logged in getEvent, and without
        // a request id, we still can't do anything
        // reasonable to report back
        const event = ev.?;
        defer ev.?.deinit();
        const event_response = event_handler(req_allocator, event.event_data) catch |err| {
            event.reportError(@errorReturnTrace(), err, lambda_runtime_uri) catch unreachable;
            continue;
        };
        event.postResponse(lambda_runtime_uri, event_response) catch |err| {
            event.reportError(@errorReturnTrace(), err, lambda_runtime_uri) catch unreachable;
            continue;
        };
    }
}

const Event = struct {
    allocator: std.mem.Allocator,
    event_data: []u8,
    request_id: []u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, event_data: []u8, request_id: []u8) Self {
        return .{
            .allocator = allocator,
            .event_data = event_data,
            .request_id = request_id,
        };
    }
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.event_data);
        self.allocator.free(self.request_id);
    }
    fn reportError(
        self: Self,
        return_trace: ?*std.builtin.StackTrace,
        err: anytype,
        lambda_runtime_uri: []const u8,
    ) !void {
        // If we fail in this function, we're pretty hosed up
        if (return_trace) |rt|
            log.err("Caught error: {}. Return Trace: {any}", .{ err, rt })
        else
            log.err("Caught error: {}. No return trace available", .{err});
        const err_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}{s}/{s}/error",
            .{ prefix, lambda_runtime_uri, postfix, self.request_id },
        );
        defer self.allocator.free(err_url);
        const err_uri = try std.Uri.parse(err_url);
        const content =
            \\{{
            \\  "errorMessage": "{s}",
            \\  "errorType": "HandlerReturnedError",
            \\  "stackTrace": [ "{any}" ]
            \\}}
        ;
        const content_fmt = if (return_trace) |rt|
            try std.fmt.allocPrint(self.allocator, content, .{ @errorName(err), rt })
        else
            try std.fmt.allocPrint(self.allocator, content, .{ @errorName(err), "no return trace available" });
        defer self.allocator.free(content_fmt);
        log.err("Posting to {s}: Data {s}", .{ err_url, content_fmt });

        var err_headers = std.http.Headers.init(self.allocator);
        defer err_headers.deinit();
        err_headers.append(
            "Lambda-Runtime-Function-Error-Type",
            "HandlerReturned",
        ) catch |append_err| {
            log.err("Error appending error header to post response for request id {s}: {}", .{ self.request_id, append_err });
            std.os.exit(1);
        };
        // TODO: There is something up with using a shared client in this way
        //       so we're taking a perf hit in favor of stability. In a practical
        //       sense, without making HTTPS connections (lambda environment is
        //       non-ssl), this shouldn't be a big issue
        var cl = std.http.Client{ .allocator = self.allocator };
        defer cl.deinit();
        var req = try cl.request(.POST, err_uri, empty_headers, .{});
        // var req = try client.?.request(.POST, err_uri, empty_headers, .{});
        // defer req.deinit();
        req.transfer_encoding = .{ .content_length = content_fmt.len };
        req.start() catch |post_err| { // Well, at this point all we can do is shout at the void
            log.err("Error posting response (start) for request id {s}: {}", .{ self.request_id, post_err });
            std.os.exit(1);
        };
        try req.writeAll(content_fmt);
        try req.finish();
        req.wait() catch |post_err| { // Well, at this point all we can do is shout at the void
            log.err("Error posting response (wait) for request id {s}: {}", .{ self.request_id, post_err });
            std.os.exit(1);
        };
        // TODO: Determine why this post is not returning
        if (req.response.status != .ok) {
            // Documentation says something about "exit immediately". The
            // Lambda infrastrucutre restarts, so it's unclear if that's necessary.
            // It seems as though a continue should be fine, and slightly faster
            log.err("Get fail: {} {s}", .{
                @intFromEnum(req.response.status),
                req.response.status.phrase() orelse "",
            });
            std.os.exit(1);
        }
        log.err("Error reporting post complete", .{});
    }

    fn postResponse(self: Self, lambda_runtime_uri: []const u8, event_response: []const u8) !void {
        const response_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}{s}/{s}/response",
            .{ prefix, lambda_runtime_uri, postfix, self.request_id },
        );
        defer self.allocator.free(response_url);
        const response_uri = try std.Uri.parse(response_url);
        var cl = std.http.Client{ .allocator = self.allocator };
        defer cl.deinit();
        var req = try cl.request(.POST, response_uri, empty_headers, .{});
        // var req = try client.?.request(.POST, response_uri, empty_headers, .{});
        defer req.deinit();
        const response_content = try std.fmt.allocPrint(
            self.allocator,
            "{{ \"content\": \"{s}\" }}",
            .{event_response},
        );
        defer self.allocator.free(response_content);

        req.transfer_encoding = .{ .content_length = response_content.len };
        try req.start();
        try req.writeAll(response_content);
        try req.finish();
        try req.wait();
    }
};

fn getEvent(allocator: std.mem.Allocator, event_data_uri: std.Uri) !?Event {
    // TODO: There is something up with using a shared client in this way
    //       so we're taking a perf hit in favor of stability. In a practical
    //       sense, without making HTTPS connections (lambda environment is
    //       non-ssl), this shouldn't be a big issue
    var cl = std.http.Client{ .allocator = allocator };
    defer cl.deinit();
    var req = try cl.request(.GET, event_data_uri, empty_headers, .{});
    // var req = try client.?.request(.GET, event_data_uri, empty_headers, .{});
    // defer req.deinit();

    try req.start();
    try req.finish();
    // Lambda freezes the process at this line of code. During warm start,
    // the process will unfreeze and data will be sent in response to client.get
    try req.wait();
    if (req.response.status != .ok) {
        // Documentation says something about "exit immediately". The
        // Lambda infrastrucutre restarts, so it's unclear if that's necessary.
        // It seems as though a continue should be fine, and slightly faster
        // std.os.exit(1);
        log.err("Lambda server event response returned bad error code: {} {s}", .{
            @intFromEnum(req.response.status),
            req.response.status.phrase() orelse "",
        });
        return error.EventResponseNotOkResponse;
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
        return null;
    }
    if (content_length == null) {
        // We can't report back an issue because the runtime error reporting endpoint
        // uses request id in its path. So the best we can do is log the error and move
        // on here.
        log.err("No content length provided for event data", .{});
        return null;
    }
    const req_id = request_id.?;
    log.debug("got lambda request with id {s}", .{req_id});

    var resp_payload = try std.ArrayList(u8).initCapacity(allocator, content_length.?);
    defer resp_payload.deinit();
    try resp_payload.resize(content_length.?);
    var response_data = try resp_payload.toOwnedSlice();
    errdefer allocator.free(response_data);
    _ = try req.readAll(response_data);

    return Event.init(
        allocator,
        response_data,
        try allocator.dupe(u8, req_id),
    );
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

fn lambda_request(allocator: std.mem.Allocator, request: []const u8, request_count: usize) ![]u8 {
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

    lambda_remaining_requests = request_count;
    server_remaining_requests = lambda_remaining_requests.? * 2; // Lambda functions
    // fetch from the server,
    // then post back. Always
    // 2, no more, no less
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
    const lambda_thread = try test_run(allocator, handler); // We want our function under test to report leaks
    lambda_thread.join();
    return try allocator.dupe(u8, server_request_aka_lambda_response);
}

test "basic request" {
    // std.testing.log_level = .debug;
    const allocator = std.testing.allocator;
    const request =
        \\{"foo": "bar", "baz": "qux"}
    ;

    // This is what's actually coming back. Is this right?
    const expected_response =
        \\{ "content": "{"foo": "bar", "baz": "qux"}" }
    ;
    const lambda_response = try lambda_request(allocator, request, 1);
    defer deinit();
    defer allocator.free(lambda_response);
    try std.testing.expectEqualStrings(expected_response, lambda_response);
}

test "several requests do not fail" {
    // std.testing.log_level = .debug;
    const allocator = std.testing.allocator;
    const request =
        \\{"foo": "bar", "baz": "qux"}
    ;

    // This is what's actually coming back. Is this right?
    const expected_response =
        \\{ "content": "{"foo": "bar", "baz": "qux"}" }
    ;
    const lambda_response = try lambda_request(allocator, request, 5);
    defer deinit();
    defer allocator.free(lambda_response);
    try std.testing.expectEqualStrings(expected_response, lambda_response);
}
