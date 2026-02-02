//! Deploy command - deploys a Lambda function to AWS.
//!
//! Creates a new function or updates an existing one.

const std = @import("std");
const aws = @import("aws");
const iam_cmd = @import("iam.zig");
const RunOptions = @import("main.zig").RunOptions;

pub fn run(args: []const []const u8, options: RunOptions) !void {
    var function_name: ?[]const u8 = null;
    var zip_file: ?[]const u8 = null;
    var role_arn: ?[]const u8 = null;
    var role_name: []const u8 = "lambda_basic_execution";
    var arch: ?[]const u8 = null;

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
    }, options);
}

fn printHelp(writer: *std.Io.Writer) void {
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
        \\  --help, -h              Show this help message
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
};

fn deployFunction(deploy_opts: DeployOptions, options: RunOptions) !void {
    // Validate architecture
    const arch_str = deploy_opts.arch orelse "x86_64";
    if (!std.mem.eql(u8, arch_str, "x86_64") and !std.mem.eql(u8, arch_str, "aarch64") and !std.mem.eql(u8, arch_str, "arm64")) {
        return error.InvalidArchitecture;
    }

    // Note: Profile is expected to be set via AWS_PROFILE env var before invoking this tool
    // (e.g., via aws-vault exec)

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

    var client = aws.Client.init(options.allocator, .{});
    defer client.deinit();

    const services = aws.Services(.{.lambda}){};

    const region = options.region orelse "us-east-1";

    const aws_options = aws.Options{
        .client = client,
        .region = region,
    };

    // Convert arch string to Lambda format
    const lambda_arch = if (std.mem.eql(u8, arch_str, "aarch64") or std.mem.eql(u8, arch_str, "arm64"))
        "arm64"
    else
        "x86_64";

    const architectures: []const []const u8 = &.{lambda_arch};

    // Try to create the function first - if it already exists, we'll update it
    std.log.info("Attempting to create function: {s}", .{deploy_opts.function_name});

    var create_diagnostics = aws.Diagnostics{
        .http_code = undefined,
        .response_body = undefined,
        .allocator = options.allocator,
    };

    const create_options = aws.Options{
        .client = client,
        .region = region,
        .diagnostics = &create_diagnostics,
    };

    const create_result = aws.Request(services.lambda.create_function).call(.{
        .function_name = deploy_opts.function_name,
        .architectures = @constCast(architectures),
        .code = .{ .zip_file = base64_data },
        .handler = "bootstrap",
        .package_type = "Zip",
        .runtime = "provided.al2023",
        .role = role_arn,
    }, create_options) catch |err| {
        defer create_diagnostics.deinit();
        std.log.info("CreateFunction returned: error={}, HTTP code={}", .{ err, create_diagnostics.http_code });

        // Function already exists (409 Conflict) - update it instead
        if (create_diagnostics.http_code == 409) {
            std.log.info("Function already exists, updating: {s}", .{deploy_opts.function_name});

            const update_result = try aws.Request(services.lambda.update_function_code).call(.{
                .function_name = deploy_opts.function_name,
                .architectures = @constCast(architectures),
                .zip_file = base64_data,
            }, aws_options);
            defer update_result.deinit();

            try options.stdout.print("Updated function: {s}\n", .{deploy_opts.function_name});
            if (update_result.response.function_arn) |arn| {
                try options.stdout.print("ARN: {s}\n", .{arn});
            }
            try options.stdout.flush();

            // Wait for function to be ready before returning
            try waitForFunctionReady(deploy_opts.function_name, aws_options);
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
    try waitForFunctionReady(deploy_opts.function_name, aws_options);
}

fn waitForFunctionReady(function_name: []const u8, aws_options: aws.Options) !void {
    const services = aws.Services(.{.lambda}){};

    var retries: usize = 30; // Up to ~6 seconds total
    while (retries > 0) : (retries -= 1) {
        const result = aws.Request(services.lambda.get_function).call(.{
            .function_name = function_name,
        }, aws_options) catch |err| {
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
