//! Invoke command - invokes a Lambda function.

const std = @import("std");
const aws = @import("aws");
const RunOptions = @import("main.zig").RunOptions;

pub fn run(args: []const []const u8, options: RunOptions) !void {
    var function_name: ?[]const u8 = null;
    var payload: []const u8 = "{}";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--function-name")) {
            i += 1;
            if (i >= args.len) return error.MissingFunctionName;
            function_name = args[i];
        } else if (std.mem.eql(u8, arg, "--payload")) {
            i += 1;
            if (i >= args.len) return error.MissingPayload;
            payload = args[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp(options.stdout);
            try options.stdout.flush();
            return;
        } else {
            try options.stderr.print("Unknown option: {s}\n", .{arg});
            try options.stderr.flush();
            return error.UnknownOption;
        }
    }

    if (function_name == null) {
        try options.stderr.print("Error: --function-name is required\n", .{});
        printHelp(options.stderr);
        try options.stderr.flush();
        return error.MissingFunctionName;
    }

    try invokeFunction(function_name.?, payload, options);
}

fn printHelp(writer: *std.Io.Writer) void {
    writer.print(
        \\Usage: lambda-build invoke [options]
        \\
        \\Invoke a Lambda function.
        \\
        \\Options:
        \\  --function-name <name>  Name of the Lambda function (required)
        \\  --payload <json>        JSON payload to send (default: empty object)
        \\  --help, -h              Show this help message
        \\
        \\The function response is printed to stdout.
        \\
    , .{}) catch {};
}

fn invokeFunction(function_name: []const u8, payload: []const u8, options: RunOptions) !void {
    // Note: Profile is expected to be set via AWS_PROFILE env var before invoking this tool
    // (e.g., via aws-vault exec)

    var client = aws.Client.init(options.allocator, .{});
    defer client.deinit();

    const services = aws.Services(.{.lambda}){};
    const region = options.region orelse "us-east-1";

    const aws_options = aws.Options{
        .client = client,
        .region = region,
    };

    std.log.info("Invoking function: {s}", .{function_name});

    const result = try aws.Request(services.lambda.invoke).call(.{
        .function_name = function_name,
        .payload = payload,
        .log_type = "Tail",
        .invocation_type = "RequestResponse",
    }, aws_options);
    defer result.deinit();

    // Print response payload
    if (result.response.payload) |response_payload| {
        try options.stdout.print("{s}\n", .{response_payload});
    }

    // Print function error if any
    if (result.response.function_error) |func_error| {
        try options.stdout.print("Function error: {s}\n", .{func_error});
    }

    // Print logs if available (base64 decoded)
    if (result.response.log_result) |log_result| {
        const decoder = std.base64.standard.Decoder;
        const decoded_len = try decoder.calcSizeForSlice(log_result);
        const decoded = try options.allocator.alloc(u8, decoded_len);
        defer options.allocator.free(decoded);
        try decoder.decode(decoded, log_result);
        try options.stdout.print("\n--- Logs ---\n{s}\n", .{decoded});
    }

    try options.stdout.flush();
}
