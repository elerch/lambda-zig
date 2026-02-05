//! Deploy command - deploys a Lambda function to AWS.
//!
//! Creates a new function or updates an existing one.
//! Supports setting environment variables via --env or --env-file.
//! Function configuration (timeout, memory, VPC, etc.) comes from --config-file.

const std = @import("std");
const aws = @import("aws");
const iam_cmd = @import("iam.zig");
const RunOptions = @import("main.zig").RunOptions;
const LambdaBuildConfig = @import("LambdaBuildConfig.zig");

// Get Lambda EnvironmentVariableKeyValue type from AWS SDK
const EnvVar = aws.services.lambda.EnvironmentVariableKeyValue;

pub fn run(args: []const []const u8, options: RunOptions) !void {
    var function_name: ?[]const u8 = null;
    var zip_file: ?[]const u8 = null;
    var role_arn: ?[]const u8 = null;
    var arch: ?[]const u8 = null;
    var deploy_output: ?[]const u8 = null;
    var config_file: ?[]const u8 = null;
    var is_config_required = false;

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
        } else if (std.mem.eql(u8, arg, "--config-file")) {
            i += 1;
            if (i >= args.len) return error.MissingConfigFile;
            config_file = args[i];
            is_config_required = true;
        } else if (std.mem.eql(u8, arg, "--config-file-optional")) {
            i += 1;
            if (i >= args.len) return error.MissingConfigFile;
            config_file = args[i];
            is_config_required = false;
        } else if (std.mem.eql(u8, arg, "--deploy-output")) {
            i += 1;
            if (i >= args.len) return error.MissingDeployOutput;
            deploy_output = args[i];
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

    // Load config file if provided
    var parsed_config = if (config_file) |path|
        try LambdaBuildConfig.loadFromFile(options.allocator, path, !is_config_required)
    else
        null;
    defer if (parsed_config) |*pc| pc.deinit();

    try deployFunction(.{
        .function_name = function_name.?,
        .zip_file = zip_file.?,
        .role_arn = role_arn,
        .arch = arch,
        .env_vars = if (env_vars.count() > 0) &env_vars else null,
        .deploy_output = deploy_output,
        .config = if (parsed_config) |pc| &pc.parsed.value else null,
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
        if (err == error.FileNotFound) {
            std.log.info("Env file '{s}' not found, skipping", .{path});
            return;
        }
        std.log.err("Failed to open env file '{s}': {}", .{ path, err });
        return error.EnvFileOpenError;
    };
    defer file.close();

    // Read entire file (env files are typically small)
    // SAFETY: set on read
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
        \\  --function-name <name>         Name of the Lambda function (required)
        \\  --zip-file <path>              Path to the deployment zip (required)
        \\  --role-arn <arn>               IAM role ARN (optional - creates role if omitted)
        \\  --arch <arch>                  Architecture: x86_64 or aarch64 (default: x86_64)
        \\  --env <KEY=VALUE>              Set environment variable (can be repeated)
        \\  --env-file <path>              Load environment variables from file
        \\  --config-file <path>           Path to JSON config file (required, error if missing)
        \\  --config-file-optional <path>  Path to JSON config file (optional, use defaults if missing)
        \\  --deploy-output <path>         Write deployment info to JSON file
        \\  --help, -h                     Show this help message
        \\
        \\Config File:
        \\  The config file specifies function settings:
        \\  {{
        \\    "role_name": "my_lambda_role",
        \\    "timeout": 30,
        \\    "memory_size": 512,
        \\    "allow_principal": "alexa-appkit.amazon.com",
        \\    "description": "My function",
        \\    "tags": [{{ "key": "Env", "value": "prod" }}]
        \\  }}
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
    arch: ?[]const u8,
    env_vars: ?*const std.StringHashMap([]const u8),
    deploy_output: ?[]const u8,
    config: ?*const LambdaBuildConfig,
};

fn deployFunction(deploy_opts: DeployOptions, options: RunOptions) !void {
    // Validate architecture
    const arch_str = deploy_opts.arch orelse "x86_64";
    if (!std.mem.eql(u8, arch_str, "x86_64") and !std.mem.eql(u8, arch_str, "aarch64") and !std.mem.eql(u8, arch_str, "arm64")) {
        return error.InvalidArchitecture;
    }

    // Get role_name from config or use default
    const role_name = if (deploy_opts.config) |c| c.role_name else "lambda_basic_execution";

    // Get or create IAM role if not provided
    const role_arn = if (deploy_opts.role_arn) |r|
        try options.allocator.dupe(u8, r)
    else
        try iam_cmd.getOrCreateRole(role_name, options);

    defer options.allocator.free(role_arn);

    // Read the zip file and encode as base64
    const zip_file = try std.fs.cwd().openFile(deploy_opts.zip_file, .{});
    defer zip_file.close();
    // SAFETY: set on read
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

    // Build config-based parameters
    const config = deploy_opts.config;

    // Build tags array if present in config
    const tags = if (config) |c| if (c.tags) |t| blk: {
        var tag_arr = try options.allocator.alloc(aws.services.lambda.TagKeyValue, t.len);
        for (t, 0..) |tag, idx| {
            tag_arr[idx] = .{ .key = tag.key, .value = tag.value };
        }
        break :blk tag_arr;
    } else null else null;
    defer if (tags) |t| options.allocator.free(t);

    // Build VPC config if present
    const vpc_config: ?aws.services.lambda.VpcConfig = if (config) |c| if (c.vpc_config) |vc|
        .{
            .subnet_ids = if (vc.subnet_ids) |ids| @constCast(ids) else null,
            .security_group_ids = if (vc.security_group_ids) |ids| @constCast(ids) else null,
            .ipv6_allowed_for_dual_stack = vc.ipv6_allowed_for_dual_stack,
        }
    else
        null else null;

    // Build dead letter config if present
    const dead_letter_config: ?aws.services.lambda.DeadLetterConfig = if (config) |c| if (c.dead_letter_config) |dlc|
        .{ .target_arn = dlc.target_arn }
    else
        null else null;

    // Build tracing config if present
    const tracing_config: ?aws.services.lambda.TracingConfig = if (config) |c| if (c.tracing_config) |tc|
        .{ .mode = tc.mode }
    else
        null else null;

    // Build ephemeral storage if present
    const ephemeral_storage: ?aws.services.lambda.EphemeralStorage = if (config) |c| if (c.ephemeral_storage) |es|
        .{ .size = es.size }
    else
        null else null;

    // Build logging config if present
    const logging_config: ?aws.services.lambda.LoggingConfig = if (config) |c| if (c.logging_config) |lc|
        .{
            .log_format = lc.log_format,
            .application_log_level = lc.application_log_level,
            .system_log_level = lc.system_log_level,
            .log_group = lc.log_group,
        }
    else
        null else null;

    // Try to create the function first - if it already exists, we'll update it
    std.log.info("Attempting to create function: {s}", .{deploy_opts.function_name});

    var create_diagnostics = aws.Diagnostics{
        // SAFETY: set by sdk on error
        .response_status = undefined,
        // SAFETY: set by sdk on error
        .response_body = undefined,
        .allocator = options.allocator,
    };

    // Use the shared aws_options but add diagnostics for create call
    var create_options = options.aws_options;
    create_options.diagnostics = &create_diagnostics;

    // Track the function ARN from whichever path succeeds
    var function_arn: ?[]const u8 = null;
    defer if (function_arn) |arn| options.allocator.free(arn);

    const create_result = aws.Request(services.lambda.create_function).call(.{
        .function_name = deploy_opts.function_name,
        .architectures = architectures,
        .code = .{ .zip_file = base64_data },
        .handler = "bootstrap",
        .package_type = "Zip",
        .runtime = "provided.al2023",
        .role = role_arn,
        .environment = if (env_variables) |vars| .{ .variables = vars } else null,
        // Config-based parameters
        .description = if (config) |c| c.description else null,
        .timeout = if (config) |c| c.timeout else null,
        .memory_size = if (config) |c| c.memory_size else null,
        .kmskey_arn = if (config) |c| c.kmskey_arn else null,
        .vpc_config = vpc_config,
        .dead_letter_config = dead_letter_config,
        .tracing_config = tracing_config,
        .ephemeral_storage = ephemeral_storage,
        .logging_config = logging_config,
        .tags = tags,
        .layers = if (config) |c| if (c.layers) |l| @constCast(l) else null else null,
    }, create_options) catch |err| {
        defer create_diagnostics.deinit();

        // Function already exists (409 Conflict) - update it instead
        if (create_diagnostics.response_status == .conflict) {
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
                function_arn = try options.allocator.dupe(u8, arn);
            }
            try options.stdout.flush();

            // Wait for function to be ready before updating configuration
            try waitForFunctionReady(deploy_opts.function_name, options);

            // Update function configuration if we have config or env variables
            if (config != null or env_variables != null)
                try updateFunctionConfiguration(
                    deploy_opts.function_name,
                    env_variables,
                    config,
                    options,
                );

            // Add invoke permission if requested
            if (config) |c|
                if (c.allow_principal) |principal|
                    try addPermission(deploy_opts.function_name, principal, options);

            // Write deploy output if requested
            if (deploy_opts.deploy_output) |output_path|
                try writeDeployOutput(output_path, function_arn.?, role_arn, lambda_arch, deploy_opts.env_vars);

            return;
        }
        std.log.err(
            "Lambda CreateFunction failed: {} (HTTP Response code {})",
            .{ err, create_diagnostics.response_status },
        );
        return error.LambdaCreateFunctionFailed;
    };
    defer create_result.deinit();

    try options.stdout.print("Created function: {s}\n", .{deploy_opts.function_name});
    if (create_result.response.function_arn) |arn| {
        try options.stdout.print("ARN: {s}\n", .{arn});
        function_arn = try options.allocator.dupe(u8, arn);
    }
    try options.stdout.flush();

    // Wait for function to be ready before returning
    try waitForFunctionReady(deploy_opts.function_name, options);

    // Add invoke permission if requested
    if (config) |c|
        if (c.allow_principal) |principal|
            try addPermission(deploy_opts.function_name, principal, options);

    // Write deploy output if requested
    if (deploy_opts.deploy_output) |output_path|
        try writeDeployOutput(output_path, function_arn.?, role_arn, lambda_arch, deploy_opts.env_vars);
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

/// Update function configuration (environment variables and config settings)
fn updateFunctionConfiguration(
    function_name: []const u8,
    env_variables: ?[]EnvVar,
    config: ?*const LambdaBuildConfig,
    options: RunOptions,
) !void {
    const services = aws.Services(.{.lambda}){};

    std.log.info("Updating function configuration for: {s}", .{function_name});

    // Build VPC config if present
    const vpc_config: ?aws.services.lambda.VpcConfig = if (config) |c| if (c.vpc_config) |vc|
        .{
            .subnet_ids = if (vc.subnet_ids) |ids| @constCast(ids) else null,
            .security_group_ids = if (vc.security_group_ids) |ids| @constCast(ids) else null,
            .ipv6_allowed_for_dual_stack = vc.ipv6_allowed_for_dual_stack,
        }
    else
        null else null;

    // Build dead letter config if present
    const dead_letter_config: ?aws.services.lambda.DeadLetterConfig = if (config) |c| if (c.dead_letter_config) |dlc|
        .{ .target_arn = dlc.target_arn }
    else
        null else null;

    // Build tracing config if present
    const tracing_config: ?aws.services.lambda.TracingConfig = if (config) |c| if (c.tracing_config) |tc|
        .{ .mode = tc.mode }
    else
        null else null;

    // Build ephemeral storage if present
    const ephemeral_storage: ?aws.services.lambda.EphemeralStorage = if (config) |c| if (c.ephemeral_storage) |es|
        .{ .size = es.size }
    else
        null else null;

    // Build logging config if present
    const logging_config: ?aws.services.lambda.LoggingConfig = if (config) |c| if (c.logging_config) |lc|
        .{
            .log_format = lc.log_format,
            .application_log_level = lc.application_log_level,
            .system_log_level = lc.system_log_level,
            .log_group = lc.log_group,
        }
    else
        null else null;

    const update_config_result = try aws.Request(services.lambda.update_function_configuration).call(.{
        .function_name = function_name,
        .environment = if (env_variables) |vars| .{ .variables = vars } else null,
        // Config-based parameters
        .description = if (config) |c| c.description else null,
        .timeout = if (config) |c| c.timeout else null,
        .memory_size = if (config) |c| c.memory_size else null,
        .kmskey_arn = if (config) |c| c.kmskey_arn else null,
        .vpc_config = vpc_config,
        .dead_letter_config = dead_letter_config,
        .tracing_config = tracing_config,
        .ephemeral_storage = ephemeral_storage,
        .logging_config = logging_config,
        .layers = if (config) |c| if (c.layers) |l| @constCast(l) else null else null,
    }, options.aws_options);
    defer update_config_result.deinit();

    try options.stdout.print("Updated function configuration\n", .{});
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
        if (result.response.configuration) |cfg| {
            if (cfg.last_update_status) |status| {
                if (std.mem.eql(u8, status, "Successful")) {
                    std.log.debug("Function is ready", .{});
                    return;
                } else if (std.mem.eql(u8, status, "Failed")) {
                    return error.FunctionUpdateFailed;
                }
                // "InProgress" - keep waiting
            } else return; // No status means it's ready
        } else return; // No configuration means we can't check, assume ready

        std.Thread.sleep(200 * std.time.ns_per_ms);
    }

    return error.FunctionNotReady;
}

/// Add invoke permission for a service principal
fn addPermission(
    function_name: []const u8,
    principal: []const u8,
    options: RunOptions,
) !void {
    const services = aws.Services(.{.lambda}){};

    // Generate statement ID from principal: "alexa-appkit.amazon.com" -> "allow-alexa-appkit-amazon-com"
    // SAFETY: set on write
    var statement_id_buf: [128]u8 = undefined;
    var statement_id_len: usize = 0;

    // Add "allow-" prefix
    const prefix = "allow-";
    @memcpy(statement_id_buf[0..prefix.len], prefix);
    statement_id_len = prefix.len;

    // Sanitize principal: replace dots with dashes
    for (principal) |c| {
        if (statement_id_len >= statement_id_buf.len - 1) break;
        statement_id_buf[statement_id_len] = if (c == '.') '-' else c;
        statement_id_len += 1;
    }

    const statement_id = statement_id_buf[0..statement_id_len];

    std.log.info("Adding invoke permission for principal: {s}", .{principal});

    var diagnostics = aws.Diagnostics{
        // SAFETY: set by sdk on error
        .response_status = undefined,
        // SAFETY: set by sdk on error
        .response_body = undefined,
        .allocator = options.allocator,
    };

    var add_perm_options = options.aws_options;
    add_perm_options.diagnostics = &diagnostics;

    const result = aws.Request(services.lambda.add_permission).call(.{
        .function_name = function_name,
        .statement_id = statement_id,
        .action = "lambda:InvokeFunction",
        .principal = principal,
    }, add_perm_options) catch |err| {
        defer diagnostics.deinit();

        // 409 Conflict means permission already exists - that's fine
        if (diagnostics.response_status == .conflict) {
            std.log.info("Permission already exists for: {s}", .{principal});
            try options.stdout.print("Permission already exists for: {s}\n", .{principal});
            try options.stdout.flush();
            return;
        }

        std.log.err(
            "AddPermission failed: {} (HTTP Response code {})",
            .{ err, diagnostics.response_status },
        );
        return error.AddPermissionFailed;
    };
    defer result.deinit();

    try options.stdout.print("Added invoke permission for: {s}\n", .{principal});
    try options.stdout.flush();
}

/// Write deployment information to a JSON file
fn writeDeployOutput(
    output_path: []const u8,
    function_arn: []const u8,
    role_arn: []const u8,
    architecture: []const u8,
    env_vars: ?*const std.StringHashMap([]const u8),
) !void {
    // Parse ARN to extract components
    // ARN format: arn:{partition}:lambda:{region}:{account_id}:function:{name}
    var arn_parts = std.mem.splitScalar(u8, function_arn, ':');
    _ = arn_parts.next(); // arn
    const partition = arn_parts.next() orelse return error.InvalidArn;
    _ = arn_parts.next(); // lambda
    const region = arn_parts.next() orelse return error.InvalidArn;
    const account_id = arn_parts.next() orelse return error.InvalidArn;
    _ = arn_parts.next(); // function
    const fn_name = arn_parts.next() orelse return error.InvalidArn;

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    // SAFETY: set on write
    var write_buffer: [4096]u8 = undefined;
    var buffered = file.writer(&write_buffer);
    const writer = &buffered.interface;

    try writer.print(
        \\{{
        \\  "arn": "{s}",
        \\  "function_name": "{s}",
        \\  "partition": "{s}",
        \\  "region": "{s}",
        \\  "account_id": "{s}",
        \\  "role_arn": "{s}",
        \\  "architecture": "{s}",
        \\  "environment_keys": [
    , .{ function_arn, fn_name, partition, region, account_id, role_arn, architecture });

    // Write environment variable keys
    if (env_vars) |vars| {
        var it = vars.keyIterator();
        var first = true;
        while (it.next()) |key| {
            if (!first) {
                try writer.writeAll(",");
            }
            try writer.print("\n    \"{s}\"", .{key.*});
            first = false;
        }
    }

    try writer.writeAll(
        \\
        \\  ]
        \\}
        \\
    );
    try writer.flush();

    std.log.info("Wrote deployment info to: {s}", .{output_path});
}
