//! Lambda Build CLI
//!
//! A command-line tool for packaging, deploying, and invoking AWS Lambda functions.
//!
//! Usage: lambda-build <command> [options]
//!
//! Commands:
//!   package    Create deployment zip from executable
//!   iam        Create/verify IAM role for Lambda
//!   deploy     Deploy function to AWS Lambda
//!   invoke     Invoke the deployed function

const std = @import("std");
const package = @import("package.zig");
const iam_cmd = @import("iam.zig");
const deploy_cmd = @import("deploy.zig");
const invoke_cmd = @import("invoke.zig");

/// Options passed to all commands
pub const RunOptions = struct {
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    region: ?[]const u8 = null,
    profile: ?[]const u8 = null,
};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);

    var options = RunOptions{
        .allocator = allocator,
        .stdout = &stdout_writer.interface,
        .stderr = &stderr_writer.interface,
    };

    run(&options) catch |err| {
        options.stderr.print("Error: {}\n", .{err}) catch {};
        options.stderr.flush() catch {};
        return 1;
    };
    try options.stderr.flush();
    try options.stdout.flush();
    return 0;
}

fn run(options: *RunOptions) !void {
    const args = try std.process.argsAlloc(options.allocator);
    defer std.process.argsFree(options.allocator, args);

    if (args.len < 2) {
        printUsage(options.stderr);
        try options.stderr.flush();
        return error.MissingCommand;
    }

    // Parse global options and find command
    var cmd_start: usize = 1;

    while (cmd_start < args.len) {
        const arg = args[cmd_start];
        if (std.mem.eql(u8, arg, "--region")) {
            cmd_start += 1;
            if (cmd_start >= args.len) return error.MissingRegionValue;
            options.region = args[cmd_start];
            cmd_start += 1;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            cmd_start += 1;
            if (cmd_start >= args.len) return error.MissingProfileValue;
            options.profile = args[cmd_start];
            cmd_start += 1;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            // Unknown global option - might be command-specific, let command handle it
            break;
        } else {
            // Found command
            break;
        }
    }

    if (cmd_start >= args.len) {
        printUsage(options.stderr);
        try options.stderr.flush();
        return error.MissingCommand;
    }

    const command = args[cmd_start];
    const cmd_args = args[cmd_start + 1 ..];

    if (std.mem.eql(u8, command, "package")) {
        try package.run(cmd_args, options.*);
    } else if (std.mem.eql(u8, command, "iam")) {
        try iam_cmd.run(cmd_args, options.*);
    } else if (std.mem.eql(u8, command, "deploy")) {
        try deploy_cmd.run(cmd_args, options.*);
    } else if (std.mem.eql(u8, command, "invoke")) {
        try invoke_cmd.run(cmd_args, options.*);
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage(options.stdout);
        try options.stdout.flush();
    } else {
        options.stderr.print("Unknown command: {s}\n\n", .{command}) catch {};
        printUsage(options.stderr);
        try options.stderr.flush();
        return error.UnknownCommand;
    }
}

fn printUsage(writer: *std.Io.Writer) void {
    writer.print(
        \\Usage: lambda-build [global-options] <command> [options]
        \\
        \\Lambda deployment CLI tool
        \\
        \\Global Options:
        \\  --region <region>       AWS region (default: from AWS config)
        \\  --profile <profile>     AWS profile to use
        \\
        \\Commands:
        \\  package    Create deployment zip from executable
        \\  iam        Create/verify IAM role for Lambda
        \\  deploy     Deploy function to AWS Lambda
        \\  invoke     Invoke the deployed function
        \\
        \\Run 'lambda-build <command> --help' for command-specific options.
        \\
    , .{}) catch {};
}
