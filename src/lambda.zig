const std = @import("std");
const builtin = @import("builtin");

const HandlerFn = *const fn (std.mem.Allocator, []const u8) anyerror![]const u8;

const log = std.log.scoped(.lambda);

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
    const lambda_runtime_uri = std.posix.getenv("AWS_LAMBDA_RUNTIME_API") orelse test_lambda_runtime_uri.?;
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
            std.posix.exit(1);
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
    event_data: []const u8,
    request_id: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, event_data: []const u8, request_id: []const u8) Self {
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

        // TODO: There is something up with using a shared client in this way
        //       so we're taking a perf hit in favor of stability. In a practical
        //       sense, without making HTTPS connections (lambda environment is
        //       non-ssl), this shouldn't be a big issue
        var cl = std.http.Client{ .allocator = self.allocator };
        defer cl.deinit();
        const res = cl.fetch(.{
            .method = .POST,
            .payload = content_fmt,
            .location = .{ .uri = err_uri },
            .extra_headers = &.{
                .{
                    .name = "Lambda-Runtime-Function-Error-Type",
                    .value = "HandlerReturned",
                },
            },
        }) catch |post_err| { // Well, at this point all we can do is shout at the void
            log.err("Error posting response (start) for request id {s}: {}", .{ self.request_id, post_err });
            std.posix.exit(1);
        };
        // TODO: Determine why this post is not returning
        if (res.status != .ok) {
            // Documentation says something about "exit immediately". The
            // Lambda infrastrucutre restarts, so it's unclear if that's necessary.
            // It seems as though a continue should be fine, and slightly faster
            log.err("Post fail: {} {s}", .{
                @intFromEnum(res.status),
                res.status.phrase() orelse "",
            });
            std.posix.exit(1);
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
        var cl = std.http.Client{ .allocator = self.allocator };
        defer cl.deinit();
        // Lambda does different things, depending on the runtime. Go 1.x takes
        // any return value but escapes double quotes. Custom runtimes can
        // do whatever they want. node I believe wraps as a json object. We're
        // going to leave the return value up to the handler, and they can
        // use a seperate API for normalization so we're explicit. As a result,
        // we can just post event_response completely raw here
        const res = try cl.fetch(.{
            .method = .POST,
            .payload = event_response,
            .location = .{ .url = response_url },
        });
        if (res.status != .ok) return error.UnexpectedStatusFromPostResponse;
    }
};

fn getEvent(allocator: std.mem.Allocator, event_data_uri: std.Uri) !?Event {
    // TODO: There is something up with using a shared client in this way
    //       so we're taking a perf hit in favor of stability. In a practical
    //       sense, without making HTTPS connections (lambda environment is
    //       non-ssl), this shouldn't be a big issue
    var cl = std.http.Client{ .allocator = allocator };
    defer cl.deinit();
    var response_bytes = std.ArrayList(u8).init(allocator);
    defer response_bytes.deinit();
    var server_header_buffer: [16 * 1024]u8 = undefined;
    // Lambda freezes the process at this line of code. During warm start,
    // the process will unfreeze and data will be sent in response to client.get
    var res = try cl.fetch(.{
        .server_header_buffer = &server_header_buffer,
        .location = .{ .uri = event_data_uri },
        .response_storage = .{ .dynamic = &response_bytes },
    });
    if (res.status != .ok) {
        // Documentation says something about "exit immediately". The
        // Lambda infrastrucutre restarts, so it's unclear if that's necessary.
        // It seems as though a continue should be fine, and slightly faster
        // std.os.exit(1);
        log.err("Lambda server event response returned bad error code: {} {s}", .{
            @intFromEnum(res.status),
            res.status.phrase() orelse "",
        });
        return error.EventResponseNotOkResponse;
    }

    var request_id: ?[]const u8 = null;
    var header_it = std.http.HeaderIterator.init(server_header_buffer[0..]);
    while (header_it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Lambda-Runtime-Aws-Request-Id"))
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
        log.err("Could not find request id: skipping request", .{});
        return null;
    }
    const req_id = request_id.?;
    log.debug("got lambda request with id {s}", .{req_id});

    return Event.init(
        allocator,
        try response_bytes.toOwnedSlice(),
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
    const address = try std.net.Address.parseIp("127.0.0.1", 0);
    var http_server = try address.listen(.{ .reuse_address = true });
    server_port = http_server.listen_address.in.getPort();

    test_lambda_runtime_uri = try std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{server_port.?});
    log.debug("server listening at {s}", .{test_lambda_runtime_uri.?});
    defer test_lambda_runtime_uri = null;
    defer server_port = null;
    log.info("starting server thread, tid {d}", .{std.Thread.getCurrentId()});
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
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

        processRequest(aa, &http_server) catch |e| {
            log.err("Unexpected error processing request: {any}", .{e});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
        };
    }
}

fn processRequest(allocator: std.mem.Allocator, server: *std.net.Server) !void {
    server_ready = true;
    errdefer server_ready = false;
    log.debug(
        "tid {d} (server): server waiting to accept. requests remaining: {d}",
        .{ std.Thread.getCurrentId(), server_remaining_requests + 1 },
    );
    var connection = try server.accept();
    defer connection.stream.close();
    server_ready = false;

    var read_buffer: [1024 * 16]u8 = undefined;
    var http_server = std.http.Server.init(connection, &read_buffer);

    if (http_server.state == .ready) {
        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                std.log.err("closing http connection: {s}", .{@errorName(err)});
                std.log.debug("Error occurred from this request: \n{s}", .{read_buffer[0..http_server.read_buffer_len]});
                return;
            },
        };
        server_request_aka_lambda_response = try (try request.reader()).readAllAlloc(allocator, std.math.maxInt(usize));
        var respond_options = std.http.Server.Request.RespondOptions{};
        const response_bytes = serve(allocator, request, &respond_options) catch |e| brk: {
            respond_options.status = .internal_server_error;
            // TODO: more about this particular request
            log.err("Unexpected error from executor processing request: {any}", .{e});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
            break :brk "Unexpected error generating request to lambda";
        };
        try request.respond(response_bytes, respond_options);
        log.debug(
            "tid {d} (server): sent response: {s}",
            .{ std.Thread.getCurrentId(), response_bytes },
        );
    }
}

fn serve(allocator: std.mem.Allocator, request: std.http.Server.Request, respond_options: *std.http.Server.Request.RespondOptions) ![]const u8 {
    _ = allocator;
    _ = request;
    respond_options.extra_headers = &.{
        .{ .name = "Lambda-Runtime-Aws-Request-Id", .value = "69" },
    };
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
    const aa = arena.allocator();
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
        \\{"foo": "bar", "baz": "qux"}
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
        \\{"foo": "bar", "baz": "qux"}
    ;
    const lambda_response = try lambda_request(allocator, request, 5);
    defer deinit();
    defer allocator.free(lambda_response);
    try std.testing.expectEqualStrings(expected_response, lambda_response);
}
