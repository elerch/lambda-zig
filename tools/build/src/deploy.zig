//! Deploy command - deploys a Lambda function to AWS.
//!
//! Creates a new function or updates an existing one.
//! Supports setting environment variables via --env or --env-file.

const std = @import("std");
const aws = @import("aws");
const iam_cmd = @import("iam.zig");
const RunOptions = @import("main.zig").RunOptions;

// Get Lambda EnvironmentVariableKeyValue type from AWS SDK
const EnvVar = aws.services.lambda.EnvironmentVariableKeyValue;

pub fn run(args: []const []const u8, options: RunOptions) !void {
    var function_name: ?[]const u8 = null;
    var zip_file: ?[]const u8 = null;
    var role_arn: ?[]const u8 = null;
    var role_name: []const u8 = "lambda_basic_execution";
    var arch: ?[]const u8 = null;

    // Environment variables storage
    var env_vars = std.StringHashMap([]const u8).init(options.allocator);
    defer {
        var it = env_vars.iterator();
        while (it.next()) |entry| {
            options.allocator.free(entry.key_ptr.*);
            options.allocator.free(entry.value_ptr.*);
        }
        env_vars.deinit();
    }

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--function-name")) {
            i += 1;
            if (i >= args.len) return error.MissingFunctionName;
            function_name = args[i];
        } else if (std.mem.eql(u8, arg, "--zip-file")) {
            i += 1;
            if (i >= args.len) return error.MissingZipFile;
            zip_file = args[i];
        } else if (std.mem.eql(u8, arg, "--role-arn")) {
            i += 1;
            if (i >= args.len) return error.MissingRoleArn;
            role_arn = args[i];
        } else if (std.mem.eql(u8, arg, "--role-name")) {
            i += 1;
            if (i >= args.len) return error.MissingRoleName;
            role_name = args[i];
        } else if (std.mem.eql(u8, arg, "--arch")) {
            i += 1;
            if (i >= args.len) return error.MissingArch;
            arch = args[i];
        } else if (std.mem.eql(u8, arg, "--env")) {
            i += 1;
            if (i >= args.len) return error.MissingEnvValue;
            try parseEnvVar(args[i], &env_vars, options.allocator);
        } else if (std.mem.eql(u8, arg, "--env-file")) {
            i += 1;
            if (i >= args.len) return error.MissingEnvFile;
            try loadEnvFile(args[i], &env_vars, options.allocator);
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

    if (zip_file == null) {
        try options.stderr.print("Error: --zip-file is required\n", .{});
        printHelp(options.stderr);
        try options.stderr.flush();
        return error.MissingZipFile;
    }

    try deployFunction(.{
        .function_name = function_name.?,
        .zip_file = zip_file.?,
        .role_arn = role_arn,
        .role_name = role_name,
        .arch = arch,
        .env_vars = if (env_vars.count() > 0) &env_vars else null,
    }, options);
}

/// Parse a KEY=VALUE string and add to the env vars map
fn parseEnvVar(
    env_str: []const u8,
    env_vars: *std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
) !void {
    const eq_pos = std.mem.indexOf(u8, env_str, "=") orelse {
        return error.InvalidEnvFormat;
    };

    const key = try allocator.dupe(u8, env_str[0..eq_pos]);
    errdefer allocator.free(key);
    const value = try allocator.dupe(u8, env_str[eq_pos + 1 ..]);
    errdefer allocator.free(value);

    // If key already exists, free the old value
    if (env_vars.fetchRemove(key)) |old| {
        allocator.free(old.key);
        allocator.free(old.value);
    }

    try env_vars.put(key, value);
}

/// Load environment variables from a file (KEY=VALUE format, one per line)
fn loadEnvFile(
    path: []const u8,
    env_vars: *std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
) !void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.log.err("Failed to open env file '{s}': {}", .{ path, err });
        return error.EnvFileNotFound;
    };
    defer file.close();

    // Read entire file (env files are typically small)
    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(&read_buffer);
    const content = file_reader.interface.allocRemaining(allocator, std.Io.Limit.limited(64 * 1024)) catch |err| {
        std.log.err("Error reading env file: {}", .{err});
        return error.EnvFileReadError;
    };
    defer allocator.free(content);

    // Parse line by line
    var line_start: usize = 0;
    for (content, 0..) |c, idx| {
        if (c == '\n') {
            const line = content[line_start..idx];
            line_start = idx + 1;

            // Skip empty lines and comments
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            try parseEnvVar(trimmed, env_vars, allocator);
        }
    }

    // Handle last line if no trailing newline
    if (line_start < content.len) {
        const line = content[line_start..];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0 and trimmed[0] != '#') {
            try parseEnvVar(trimmed, env_vars, allocator);
        }
    }
}

fn printHelp(writer: anytype) void {
    writer.print(
        \\Usage: lambda-build deploy [options]
        \\
        \\Deploy a Lambda function to AWS.
        \\
        \\Options:
        \\  --function-name <name>  Name of the Lambda function (required)
        \\  --zip-file <path>       Path to the deployment zip (required)
        \\  --role-arn <arn>        IAM role ARN (optional - creates role if omitted)
        \\  --role-name <name>      IAM role name if creating (default: lambda_basic_execution)
        \\  --arch <arch>           Architecture: x86_64 or aarch64 (default: x86_64)
        \\  --env <KEY=VALUE>       Set environment variable (can be repeated)
        \\  --env-file <path>       Load environment variables from file (KEY=VALUE format)
        \\  --help, -h              Show this help message
        \\
        \\Environment File Format:
        \\  The --env-file option reads a file with KEY=VALUE pairs, one per line.
        \\  Lines starting with # are treated as comments. Empty lines are ignored.
        \\
        \\  Example .env file:
        \\    # Database configuration
        \\    DB_HOST=localhost
        \\    DB_PORT=5432
        \\
        \\If the function exists, its code is updated. Otherwise, a new function
        \\is created with the provided configuration.
        \\
    , .{}) catch {};
}

const DeployOptions = struct {
    function_name: []const u8,
    zip_file: []const u8,
    role_arn: ?[]const u8,
    role_name: []const u8,
    arch: ?[]const u8,
    env_vars: ?*const std.StringHashMap([]const u8),
};

fn deployFunction(deploy_opts: DeployOptions, options: RunOptions) !void {
    // Validate architecture
    const arch_str = deploy_opts.arch orelse "x86_64";
    if (!std.mem.eql(u8, arch_str, "x86_64") and !std.mem.eql(u8, arch_str, "aarch64") and !std.mem.eql(u8, arch_str, "arm64")) {
        return error.InvalidArchitecture;
    }

    // Get or create IAM role if not provided
    const role_arn = if (deploy_opts.role_arn) |r|
        try options.allocator.dupe(u8, r)
    else
        try iam_cmd.getOrCreateRole(deploy_opts.role_name, options);

    defer options.allocator.free(role_arn);

    // Read the zip file and encode as base64
    const zip_file = try std.fs.cwd().openFile(deploy_opts.zip_file, .{});
    defer zip_file.close();
    var read_buffer: [4096]u8 = undefined;
    var file_reader = zip_file.reader(&read_buffer);
    const zip_data = try file_reader.interface.allocRemaining(options.allocator, std.Io.Limit.limited(50 * 1024 * 1024));
    defer options.allocator.free(zip_data);

    const base64_data = try std.fmt.allocPrint(options.allocator, "{b64}", .{zip_data});
    defer options.allocator.free(base64_data);

    const services = aws.Services(.{.lambda}){};

    // Convert arch string to Lambda format
    const lambda_arch: []const u8 = if (std.mem.eql(u8, arch_str, "aarch64") or std.mem.eql(u8, arch_str, "arm64"))
        "arm64"
    else
        "x86_64";

    // Use a mutable array so the slice type is [][]const u8, not []const []const u8
    var architectures_arr = [_][]const u8{lambda_arch};
    const architectures: [][]const u8 = &architectures_arr;

    // Build environment variables for AWS API
    const env_variables = try buildEnvVariables(deploy_opts.env_vars, options.allocator);
    defer if (env_variables) |vars| {
        for (vars) |v| {
            options.allocator.free(v.key);
            if (v.value) |val| options.allocator.free(val);
        }
        options.allocator.free(vars);
    };

    // Try to create the function first - if it already exists, we'll update it
    std.log.info("Attempting to create function: {s}", .{deploy_opts.function_name});

    var create_diagnostics = aws.Diagnostics{
        .http_code = undefined,
        .response_body = undefined,
        .allocator = options.allocator,
    };

    // Use the shared aws_options but add diagnostics for create call
    var create_options = options.aws_options;
    create_options.diagnostics = &create_diagnostics;

    const create_result = aws.Request(services.lambda.create_function).call(.{
        .function_name = deploy_opts.function_name,
        .architectures = architectures,
        .code = .{ .zip_file = base64_data },
        .handler = "bootstrap",
        .package_type = "Zip",
        .runtime = "provided.al2023",
        .role = role_arn,
        .environment = if (env_variables) |vars| .{ .variables = vars } else null,
    }, create_options) catch |err| {
        defer create_diagnostics.deinit();
        std.log.info("CreateFunction returned: error={}, HTTP code={}", .{ err, create_diagnostics.http_code });

        // Function already exists (409 Conflict) - update it instead
        if (create_diagnostics.http_code == 409) {
            std.log.info("Function already exists, updating: {s}", .{deploy_opts.function_name});

            const update_result = try aws.Request(services.lambda.update_function_code).call(.{
                .function_name = deploy_opts.function_name,
                .architectures = architectures,
                .zip_file = base64_data,
            }, options.aws_options);
            defer update_result.deinit();

            try options.stdout.print("Updated function: {s}\n", .{deploy_opts.function_name});
            if (update_result.response.function_arn) |arn| {
                try options.stdout.print("ARN: {s}\n", .{arn});
            }
            try options.stdout.flush();

            // Wait for function to be ready before updating configuration
            try waitForFunctionReady(deploy_opts.function_name, options);

            // Update environment variables if provided
            if (env_variables) |vars| {
                try updateFunctionConfiguration(deploy_opts.function_name, vars, options);
            }

            return;
        }

        std.log.err("Lambda CreateFunction failed: {} (HTTP {})", .{ err, create_diagnostics.http_code });
        return error.LambdaCreateFunctionFailed;
    };
    defer create_result.deinit();

    try options.stdout.print("Created function: {s}\n", .{deploy_opts.function_name});
    if (create_result.response.function_arn) |arn| {
        try options.stdout.print("ARN: {s}\n", .{arn});
    }
    try options.stdout.flush();

    // Wait for function to be ready before returning
    try waitForFunctionReady(deploy_opts.function_name, options);
}

/// Build environment variables in the format expected by AWS Lambda API
fn buildEnvVariables(
    env_vars: ?*const std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
) !?[]EnvVar {
    const vars = env_vars orelse return null;
    if (vars.count() == 0) return null;

    var result = try allocator.alloc(EnvVar, vars.count());
    errdefer allocator.free(result);

    var idx: usize = 0;
    var it = vars.iterator();
    while (it.next()) |entry| {
        result[idx] = .{
            .key = try allocator.dupe(u8, entry.key_ptr.*),
            .value = try allocator.dupe(u8, entry.value_ptr.*),
        };
        idx += 1;
    }

    return result;
}

/// Update function configuration (environment variables)
fn updateFunctionConfiguration(
    function_name: []const u8,
    env_variables: []EnvVar,
    options: RunOptions,
) !void {
    const services = aws.Services(.{.lambda}){};

    std.log.info("Updating function configuration for: {s}", .{function_name});

    const update_config_result = try aws.Request(services.lambda.update_function_configuration).call(.{
        .function_name = function_name,
        .environment = .{ .variables = env_variables },
    }, options.aws_options);
    defer update_config_result.deinit();

    try options.stdout.print("Updated environment variables\n", .{});
    try options.stdout.flush();

    // Wait for configuration update to complete
    try waitForFunctionReady(function_name, options);
}

fn waitForFunctionReady(function_name: []const u8, options: RunOptions) !void {
    const services = aws.Services(.{.lambda}){};

    var retries: usize = 30; // Up to ~6 seconds total
    while (retries > 0) : (retries -= 1) {
        const result = aws.Request(services.lambda.get_function).call(.{
            .function_name = function_name,
        }, options.aws_options) catch |err| {
            // Function should exist at this point, but retry on transient errors
            std.log.warn("GetFunction failed during wait: {}", .{err});
            std.Thread.sleep(200 * std.time.ns_per_ms);
            continue;
        };
        defer result.deinit();

        // Check if function is ready
        if (result.response.configuration) |config| {
            if (config.last_update_status) |status| {
                if (std.mem.eql(u8, status, "Successful")) {
                    std.log.info("Function is ready", .{});
                    return;
                } else if (std.mem.eql(u8, status, "Failed")) {
                    return error.FunctionUpdateFailed;
                }
                // "InProgress" - keep waiting
            } else {
                return; // No status means it's ready
            }
        } else {
            return; // No configuration means we can't check, assume ready
        }

        std.Thread.sleep(200 * std.time.ns_per_ms);
    }

    return error.FunctionNotReady;
}
