//! Lambda build configuration types.
//!
//! These types define the JSON schema for lambda.json configuration files,
//! encompassing IAM, Lambda function, and deployment settings.
//!
//! Used by both the build system (lambdabuild.zig) and the CLI commands
//! (deploy.zig, iam.zig).

const std = @import("std");

const LambdaBuildConfig = @This();

/// Wrapper for parsed config that owns both the JSON parse result
/// and the source file data (since parsed strings point into it).
pub const Parsed = struct {
    parsed: std.json.Parsed(LambdaBuildConfig),
    source_data: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Parsed) void {
        self.parsed.deinit();
        self.allocator.free(self.source_data);
    }
};

// === IAM Configuration ===

/// IAM role name for the Lambda function.
role_name: []const u8 = "lambda_basic_execution",
// Future: policy_statements, trust_policy, etc.

// === Deployment Settings ===

/// AWS service principal to grant invoke permission.
/// Example: "alexa-appkit.amazon.com" for Alexa Skills.
allow_principal: ?[]const u8 = null,

// === Lambda Function Configuration ===

/// Human-readable description of the function.
description: ?[]const u8 = null,

/// Maximum execution time in seconds (1-900).
timeout: ?i64 = null,

/// Memory allocation in MB (128-10240).
memory_size: ?i64 = null,

/// KMS key ARN for environment variable encryption.
kmskey_arn: ?[]const u8 = null,

// Nested configs
vpc_config: ?VpcConfig = null,
dead_letter_config: ?DeadLetterConfig = null,
tracing_config: ?TracingConfig = null,
ephemeral_storage: ?EphemeralStorage = null,
logging_config: ?LoggingConfig = null,

// Collections
tags: ?[]const Tag = null,
layers: ?[]const []const u8 = null,

pub const VpcConfig = struct {
    subnet_ids: ?[]const []const u8 = null,
    security_group_ids: ?[]const []const u8 = null,
    ipv6_allowed_for_dual_stack: ?bool = null,
};

pub const DeadLetterConfig = struct {
    target_arn: ?[]const u8 = null,
};

pub const TracingConfig = struct {
    /// "Active" or "PassThrough"
    mode: ?[]const u8 = null,
};

pub const EphemeralStorage = struct {
    /// Size in MB (512-10240)
    size: i64,
};

pub const LoggingConfig = struct {
    /// "JSON" or "Text"
    log_format: ?[]const u8 = null,
    /// "TRACE", "DEBUG", "INFO", "WARN", "ERROR", "FATAL"
    application_log_level: ?[]const u8 = null,
    system_log_level: ?[]const u8 = null,
    log_group: ?[]const u8 = null,
};

pub const Tag = struct {
    key: []const u8,
    value: []const u8,
};

/// Validate configuration values are within AWS limits.
pub fn validate(self: LambdaBuildConfig) !void {
    // Timeout: 1-900 seconds
    if (self.timeout) |t| {
        if (t < 1 or t > 900) {
            std.log.err("Invalid timeout: {} (must be 1-900 seconds)", .{t});
            return error.InvalidTimeout;
        }
    }

    // Memory: 128-10240 MB
    if (self.memory_size) |m| {
        if (m < 128 or m > 10240) {
            std.log.err("Invalid memory_size: {} (must be 128-10240 MB)", .{m});
            return error.InvalidMemorySize;
        }
    }

    // Ephemeral storage: 512-10240 MB
    if (self.ephemeral_storage) |es| {
        if (es.size < 512 or es.size > 10240) {
            std.log.err("Invalid ephemeral_storage.size: {} (must be 512-10240 MB)", .{es.size});
            return error.InvalidEphemeralStorage;
        }
    }

    // Tracing mode validation
    if (self.tracing_config) |tc| {
        if (tc.mode) |mode| {
            if (!std.mem.eql(u8, mode, "Active") and !std.mem.eql(u8, mode, "PassThrough")) {
                std.log.err("Invalid tracing_config.mode: '{s}' (must be 'Active' or 'PassThrough')", .{mode});
                return error.InvalidTracingMode;
            }
        }
    }

    // Log format validation
    if (self.logging_config) |lc| {
        if (lc.log_format) |format| {
            if (!std.mem.eql(u8, format, "JSON") and !std.mem.eql(u8, format, "Text")) {
                std.log.err("Invalid logging_config.log_format: '{s}' (must be 'JSON' or 'Text')", .{format});
                return error.InvalidLogFormat;
            }
        }
    }
}

/// Load configuration from a JSON file.
///
/// If is_default is true and the file doesn't exist, returns null.
/// If is_default is false (explicitly specified) and file doesn't exist, returns error.
pub fn loadFromFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    is_default: bool,
) !?Parsed {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            if (is_default) {
                std.log.debug("Config file '{s}' not found, using defaults", .{path});
                return null;
            }
            std.log.err("Config file not found: {s}", .{path});
            return error.ConfigFileNotFound;
        }
        std.log.err("Failed to open config file '{s}': {}", .{ path, err });
        return error.ConfigFileOpenError;
    };
    defer file.close();

    // Read entire file
    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(&read_buffer);
    const content = file_reader.interface.allocRemaining(allocator, std.Io.Limit.limited(64 * 1024)) catch |err| {
        std.log.err("Error reading config file: {}", .{err});
        return error.ConfigFileReadError;
    };
    errdefer allocator.free(content);

    // Parse JSON - strings will point into content, which we keep alive
    const parsed = std.json.parseFromSlice(
        LambdaBuildConfig,
        allocator,
        content,
        .{},
    ) catch |err| {
        std.log.err("Error parsing config JSON: {}", .{err});
        return error.ConfigFileParseError;
    };
    errdefer parsed.deinit();

    try parsed.value.validate();

    return .{
        .parsed = parsed,
        .source_data = content,
        .allocator = allocator,
    };
}
