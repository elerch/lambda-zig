//! Lambda Build Integration for Zig Build System
//!
//! This module provides build steps for packaging and deploying Lambda functions.
//! It builds the lambda-build CLI tool and invokes it for each operation.

const std = @import("std");

pub const LambdaBuildConfig = @import("tools/build/src/LambdaBuildConfig.zig");

/// A config file path with explicit required/optional semantics.
pub const ConfigFile = struct {
    path: std.Build.LazyPath,
    /// If true (default), error when file is missing. If false, silently use defaults.
    required: bool = true,
};

/// Source for Lambda build configuration.
///
/// Determines how Lambda function settings (timeout, memory, VPC, etc.)
/// and deployment settings (role_name, allow_principal) are provided.
pub const LambdaConfigSource = union(enum) {
    /// No configuration file. Uses hardcoded defaults.
    none,

    /// Path to a JSON config file with explicit required/optional semantics.
    file: ConfigFile,

    /// Inline configuration. Will be serialized to JSON and
    /// written to a generated file.
    config: LambdaBuildConfig,
};

/// Options for Lambda build integration.
///
/// These provide project-level defaults that can still be overridden
/// via command-line options (e.g., `-Dfunction-name=...`).
pub const Options = struct {
    /// Default function name if not specified via -Dfunction-name.
    /// If null, falls back to the executable name (exe.name).
    default_function_name: ?[]const u8 = null,

    /// Default environment file if not specified via -Denv-file.
    /// If the file doesn't exist, it's silently skipped.
    default_env_file: ?[]const u8 = ".env",

    /// Lambda build configuration source.
    /// Defaults to looking for "lambda.json" (optional - uses defaults if missing).
    ///
    /// Examples:
    /// - `.none`: No config file, use defaults
    /// - `.{ .file = .{ .path = b.path("lambda.json") } }`: Required config file
    /// - `.{ .file = .{ .path = b.path("lambda.json"), .required = false } }`: Optional config file
    /// - `.{ .config = .{ ... } }`: Inline configuration
    lambda_config: LambdaConfigSource = .{ .file = .{ .path = .{ .cwd_relative = "lambda.json" }, .required = false } },
};

/// Information about the configured Lambda build steps.
///
/// Returned by `configureBuild` to allow consumers to depend on steps
/// and access deployment outputs.
pub const BuildInfo = struct {
    /// Package step - creates the deployment zip
    package_step: *std.Build.Step,

    /// IAM step - creates/verifies the IAM role
    iam_step: *std.Build.Step,

    /// Deploy step - deploys the function to AWS Lambda
    deploy_step: *std.Build.Step,

    /// Invoke step - invokes the deployed function
    invoke_step: *std.Build.Step,

    /// LazyPath to JSON file with deployment info.
    /// Contains: arn, function_name, region, account_id, role_arn, architecture, environment_keys
    /// Available after deploy_step completes.
    deploy_output: std.Build.LazyPath,

    /// The function name used for deployment
    function_name: []const u8,
};

/// Configure Lambda build steps for a Zig project.
///
/// Adds the following build steps:
/// - awslambda_package: Package the function into a zip file
/// - awslambda_iam: Create/verify IAM role
/// - awslambda_deploy: Deploy the function to AWS
/// - awslambda_run: Invoke the deployed function
///
/// ## Configuration
///
/// Function settings (timeout, memory, VPC, etc.) and deployment settings
/// (role_name, allow_principal) are configured via a JSON file or inline config.
///
/// By default, looks for `lambda.json` in the project root. If not found,
/// uses sensible defaults (role_name = "lambda_basic_execution").
///
/// ### Example lambda.json
///
/// ```json
/// {
///   "role_name": "my_lambda_role",
///   "timeout": 30,
///   "memory_size": 512,
///   "allow_principal": "alexa-appkit.amazon.com",
///   "tags": [
///     { "key": "Environment", "value": "production" }
///   ]
/// }
/// ```
///
/// ### Inline Configuration
///
/// ```zig
/// lambda.configureBuild(b, dep, exe, .{
///     .lambda_config = .{ .config = .{
///         .role_name = "my_role",
///         .timeout = 30,
///         .memory_size = 512,
///     }},
/// });
/// ```
///
/// Returns a `BuildInfo` struct containing references to all steps and
/// a `deploy_output` LazyPath to the deployment info JSON file.
pub fn configureBuild(
    b: *std.Build,
    lambda_build_dep: *std.Build.Dependency,
    exe: *std.Build.Step.Compile,
    options: Options,
) !BuildInfo {
    // Get the lambda-build CLI artifact from the dependency
    const cli = lambda_build_dep.artifact("lambda-build");

    // Get configuration options (command-line overrides config defaults)
    const function_name = b.option([]const u8, "function-name", "Function name for Lambda") orelse options.default_function_name orelse exe.name;
    const region = b.option([]const u8, "region", "AWS region") orelse null;
    const profile = b.option([]const u8, "profile", "AWS profile") orelse null;
    const payload = b.option(
        []const u8,
        "payload",
        "Lambda invocation payload",
    ) orelse "{}";
    const env_file = b.option(
        []const u8,
        "env-file",
        "Path to environment variables file (KEY=VALUE format)",
    ) orelse options.default_env_file;
    const config_file_override = b.option(
        []const u8,
        "config-file",
        "Path to Lambda build config JSON file (overrides function_config)",
    );

    // Determine architecture for Lambda
    const target_arch = exe.root_module.resolved_target.?.result.cpu.arch;
    const arch_str = blk: {
        switch (target_arch) {
            .aarch64 => break :blk "aarch64",
            .x86_64 => break :blk "x86_64",
            else => {
                std.log.warn("Unsupported architecture for Lambda: {}, defaulting to x86_64", .{target_arch});
                break :blk "x86_64";
            },
        }
    };

    // Determine config file source - resolves to a path and required flag
    // Internal struct since we need nullable path for the .none case
    const ResolvedConfig = struct {
        path: ?std.Build.LazyPath,
        required: bool,
    };

    const config_file: ResolvedConfig = if (config_file_override) |override|
        .{ .path = .{ .cwd_relative = override }, .required = true }
    else switch (options.lambda_config) {
        .none => .{ .path = null, .required = false },
        .file => |cf| .{ .path = cf.path, .required = cf.required },
        .config => |func_config| blk: {
            // Serialize inline config to JSON and write to generated file
            const json_content = std.fmt.allocPrint(b.allocator, "{f}", .{
                std.json.fmt(func_config, .{}),
            }) catch @panic("OOM");
            const wf = b.addWriteFiles();
            break :blk .{ .path = wf.add("lambda-config.json", json_content), .required = true };
        },
    };

    // Helper to add config file arg to a command
    const addConfigArg = struct {
        fn add(cmd: *std.Build.Step.Run, file: ResolvedConfig) void {
            if (file.path) |f| {
                const flag = if (file.required) "--config-file" else "--config-file-optional";
                cmd.addArg(flag);
                cmd.addFileArg(f);
            }
        }
    }.add;

    // Package step - output goes to cache based on input hash
    const package_cmd = b.addRunArtifact(cli);
    package_cmd.step.name = try std.fmt.allocPrint(b.allocator, "{s} package", .{cli.name});
    package_cmd.addArgs(&.{ "package", "--exe" });
    package_cmd.addFileArg(exe.getEmittedBin());
    package_cmd.addArgs(&.{"--output"});
    const zip_output = package_cmd.addOutputFileArg("function.zip");
    package_cmd.step.dependOn(&exe.step);

    const package_step = b.step("awslambda_package", "Package the Lambda function");
    package_step.dependOn(&package_cmd.step);

    // IAM step
    const iam_cmd = b.addRunArtifact(cli);
    iam_cmd.step.name = try std.fmt.allocPrint(b.allocator, "{s} iam", .{cli.name});
    if (profile) |p| iam_cmd.addArgs(&.{ "--profile", p });
    if (region) |r| iam_cmd.addArgs(&.{ "--region", r });
    iam_cmd.addArg("iam");
    addConfigArg(iam_cmd, config_file);

    const iam_step = b.step("awslambda_iam", "Create/verify IAM role for Lambda");
    iam_step.dependOn(&iam_cmd.step);

    // Deploy step (depends on package)
    // NOTE: has_side_effects = true ensures this always runs, since AWS state
    // can change externally (e.g., function deleted via console)
    const deploy_cmd = b.addRunArtifact(cli);
    deploy_cmd.has_side_effects = true;
    deploy_cmd.step.name = try std.fmt.allocPrint(b.allocator, "{s} deploy", .{cli.name});
    if (profile) |p| deploy_cmd.addArgs(&.{ "--profile", p });
    if (region) |r| deploy_cmd.addArgs(&.{ "--region", r });
    deploy_cmd.addArgs(&.{
        "deploy",
        "--function-name",
        function_name,
        "--zip-file",
    });
    deploy_cmd.addFileArg(zip_output);
    deploy_cmd.addArgs(&.{
        "--arch",
        arch_str,
    });
    if (env_file) |ef| deploy_cmd.addArgs(&.{ "--env-file", ef });
    addConfigArg(deploy_cmd, config_file);
    // Add deploy output file for deployment info JSON
    deploy_cmd.addArg("--deploy-output");
    const deploy_output = deploy_cmd.addOutputFileArg("deploy-output.json");
    deploy_cmd.step.dependOn(&package_cmd.step);

    const deploy_step = b.step("awslambda_deploy", "Deploy the Lambda function");
    deploy_step.dependOn(&deploy_cmd.step);

    // Invoke/run step (depends on deploy)
    const invoke_cmd = b.addRunArtifact(cli);
    invoke_cmd.step.name = try std.fmt.allocPrint(b.allocator, "{s} invoke", .{cli.name});
    if (profile) |p| invoke_cmd.addArgs(&.{ "--profile", p });
    if (region) |r| invoke_cmd.addArgs(&.{ "--region", r });
    invoke_cmd.addArgs(&.{
        "invoke",
        "--function-name",
        function_name,
        "--payload",
        payload,
    });
    invoke_cmd.step.dependOn(&deploy_cmd.step);

    const run_step = b.step("awslambda_run", "Invoke the deployed Lambda function");
    run_step.dependOn(&invoke_cmd.step);

    return .{
        .package_step = package_step,
        .iam_step = iam_step,
        .deploy_step = deploy_step,
        .invoke_step = run_step,
        .deploy_output = deploy_output,
        .function_name = function_name,
    };
}
