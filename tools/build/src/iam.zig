//! IAM command - creates or retrieves an IAM role for Lambda execution.

const std = @import("std");
const aws = @import("aws");
const RunOptions = @import("main.zig").RunOptions;

pub fn run(args: []const []const u8, options: RunOptions) !void {
    var role_name: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--role-name")) {
            i += 1;
            if (i >= args.len) return error.MissingRoleName;
            role_name = args[i];
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

    if (role_name == null) {
        try options.stderr.print("Error: --role-name is required\n", .{});
        printHelp(options.stderr);
        try options.stderr.flush();
        return error.MissingRoleName;
    }

    const arn = try getOrCreateRole(role_name.?, options);
    defer options.allocator.free(arn);

    try options.stdout.print("{s}\n", .{arn});
    try options.stdout.flush();
}

fn printHelp(writer: *std.Io.Writer) void {
    writer.print(
        \\Usage: lambda-build iam [options]
        \\
        \\Create or retrieve an IAM role for Lambda execution.
        \\
        \\Options:
        \\  --role-name <name>  Name of the IAM role (required)
        \\  --help, -h          Show this help message
        \\
        \\If the role exists, its ARN is returned. If not, a new role is created
        \\with the AWSLambdaExecute policy attached.
        \\
    , .{}) catch {};
}

/// Get or create an IAM role for Lambda execution
/// Returns the role ARN
pub fn getOrCreateRole(role_name: []const u8, options: RunOptions) ![]const u8 {
    var client = aws.Client.init(options.allocator, .{});
    defer client.deinit();

    // Try to get existing role
    const services = aws.Services(.{.iam}){};

    var diagnostics = aws.Diagnostics{
        .http_code = undefined,
        .response_body = undefined,
        .allocator = options.allocator,
    };

    const aws_options = aws.Options{
        .client = client,
        .diagnostics = &diagnostics,
        .credential_options = .{ .profile = .{ .profile_name = options.profile } },
    };

    const get_result = aws.Request(services.iam.get_role).call(.{
        .role_name = role_name,
    }, aws_options) catch |err| {
        defer diagnostics.deinit();
        if (diagnostics.http_code == 404) {
            // Role doesn't exist, create it
            return try createRole(options.allocator, role_name, client, options.profile);
        }
        std.log.err("IAM GetRole failed: {} (HTTP {})", .{ err, diagnostics.http_code });
        return error.IamGetRoleFailed;
    };
    defer get_result.deinit();

    // Role exists, return ARN
    return try options.allocator.dupe(u8, get_result.response.role.arn);
}

fn createRole(allocator: std.mem.Allocator, role_name: []const u8, client: aws.Client, profile: ?[]const u8) ![]const u8 {
    const services = aws.Services(.{.iam}){};

    const aws_options = aws.Options{
        .client = client,
        .credential_options = .{ .profile = .{ .profile_name = profile } },
    };

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
    }, aws_options);
    defer create_result.deinit();

    const arn = try allocator.dupe(u8, create_result.response.role.arn);

    // Attach the Lambda execution policy
    std.log.info("Attaching AWSLambdaExecute policy", .{});

    const attach_result = try aws.Request(services.iam.attach_role_policy).call(.{
        .policy_arn = "arn:aws:iam::aws:policy/AWSLambdaExecute",
        .role_name = role_name,
    }, aws_options);
    defer attach_result.deinit();

    // IAM role creation can take a moment to propagate
    std.log.info("Role created: {s}", .{arn});
    std.log.info("Note: New roles may take a few seconds to propagate", .{});

    return arn;
}
