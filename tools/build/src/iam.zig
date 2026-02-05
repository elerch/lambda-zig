//! IAM command - creates or retrieves an IAM role for Lambda execution.

const std = @import("std");
const aws = @import("aws");
const RunOptions = @import("main.zig").RunOptions;
const LambdaBuildConfig = @import("LambdaBuildConfig.zig");

pub fn run(args: []const []const u8, options: RunOptions) !void {
    var config_file: ?[]const u8 = null;
    var is_config_required = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--config-file")) {
            i += 1;
            if (i >= args.len) return error.MissingConfigFile;
            config_file = args[i];
            is_config_required = true;
        } else if (std.mem.eql(u8, arg, "--config-file-optional")) {
            i += 1;
            if (i >= args.len) return error.MissingConfigFile;
            config_file = args[i];
            is_config_required = false;
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

    // Load config file if provided
    var parsed_config = if (config_file) |path|
        try LambdaBuildConfig.loadFromFile(options.allocator, path, !is_config_required)
    else
        null;
    defer if (parsed_config) |*pc| pc.deinit();

    // Get role_name from config or use default
    const role_name = if (parsed_config) |pc|
        pc.parsed.value.role_name
    else
        "lambda_basic_execution";

    const arn = try getOrCreateRole(role_name, options);
    defer options.allocator.free(arn);

    try options.stdout.print("{s}\n", .{arn});
    try options.stdout.flush();
}

fn printHelp(writer: anytype) void {
    writer.print(
        \\Usage: lambda-build iam [options]
        \\
        \\Create or retrieve an IAM role for Lambda execution.
        \\
        \\Options:
        \\  --config-file <path>           Path to JSON config file (required, error if missing)
        \\  --config-file-optional <path>  Path to JSON config file (optional, use defaults if missing)
        \\  --help, -h                     Show this help message
        \\
        \\Config File:
        \\  The config file can specify the IAM role name:
        \\  {{
        \\    "role_name": "my_lambda_role"
        \\  }}
        \\
        \\If no config file is provided, uses "lambda_basic_execution" as the role name.
        \\If the role exists, its ARN is returned. If not, a new role is created
        \\with the AWSLambdaExecute policy attached.
        \\
    , .{}) catch {};
}

/// Get or create an IAM role for Lambda execution
/// Returns the role ARN
pub fn getOrCreateRole(role_name: []const u8, options: RunOptions) ![]const u8 {
    const services = aws.Services(.{.iam}){};

    var diagnostics = aws.Diagnostics{
        // SAFETY: set by sdk on error
        .response_status = undefined,
        // SAFETY: set by sdk on error
        .response_body = undefined,
        .allocator = options.allocator,
    };

    // Use the shared aws_options but add diagnostics for this call
    var aws_options = options.aws_options;
    aws_options.diagnostics = &diagnostics;
    defer aws_options.diagnostics = null;

    const get_result = aws.Request(services.iam.get_role).call(.{
        .role_name = role_name,
    }, aws_options) catch |err| {
        defer diagnostics.deinit();

        // Check for "not found" via HTTP status or error response body
        if (diagnostics.response_status == .not_found or
            std.mem.indexOf(u8, diagnostics.response_body, "NoSuchEntity") != null)
            // Role doesn't exist, create it
            return try createRole(role_name, options);

        std.log.err("IAM GetRole failed: {} (HTTP {})", .{ err, diagnostics.response_status });
        return error.IamGetRoleFailed;
    };
    defer get_result.deinit();

    // Role exists, return ARN
    return try options.allocator.dupe(u8, get_result.response.role.arn);
}

fn createRole(role_name: []const u8, options: RunOptions) ![]const u8 {
    const services = aws.Services(.{.iam}){};

    const assume_role_policy =
        \\{
        \\  "Version": "2012-10-17",
        \\  "Statement": [
        \\    {
        \\      "Sid": "",
        \\      "Effect": "Allow",
        \\      "Principal": {
        \\        "Service": "lambda.amazonaws.com"
        \\      },
        \\      "Action": "sts:AssumeRole"
        \\    }
        \\  ]
        \\}
    ;

    std.log.info("Creating IAM role: {s}", .{role_name});

    const create_result = try aws.Request(services.iam.create_role).call(.{
        .role_name = role_name,
        .assume_role_policy_document = assume_role_policy,
    }, options.aws_options);
    defer create_result.deinit();

    const arn = try options.allocator.dupe(u8, create_result.response.role.arn);

    // Attach the Lambda execution policy
    std.log.info("Attaching AWSLambdaExecute policy", .{});

    const attach_result = try aws.Request(services.iam.attach_role_policy).call(.{
        .policy_arn = "arn:aws:iam::aws:policy/AWSLambdaExecute",
        .role_name = role_name,
    }, options.aws_options);
    defer attach_result.deinit();

    // IAM role creation can take a moment to propagate
    std.log.info("Role created: {s}", .{arn});
    std.log.info("Note: New roles may take a few seconds to propagate", .{});

    return arn;
}
