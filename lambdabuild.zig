//! Lambda Build Integration for Zig Build System
//!
//! This module provides build steps for packaging and deploying Lambda functions.
//! It builds the lambda-build CLI tool and invokes it for each operation.

const std = @import("std");

/// Configuration options for Lambda build integration.
///
/// These provide project-level defaults that can still be overridden
/// via command-line options (e.g., `-Dfunction-name=...`).
pub const Config = struct {
    /// Default function name if not specified via -Dfunction-name.
    /// This allows consuming projects to set their own default.
    default_function_name: []const u8 = "zig-fn",

    /// Default IAM role name if not specified via -Drole-name.
    default_role_name: []const u8 = "lambda_basic_execution",
};

/// Configure Lambda build steps for a Zig project.
///
/// Adds the following build steps:
/// - awslambda_package: Package the function into a zip file
/// - awslambda_iam: Create/verify IAM role
/// - awslambda_deploy: Deploy the function to AWS
/// - awslambda_run: Invoke the deployed function
///
/// The `config` parameter allows setting project-level defaults that can
/// still be overridden via command-line options.
pub fn configureBuild(
    b: *std.Build,
    lambda_build_dep: *std.Build.Dependency,
    exe: *std.Build.Step.Compile,
    config: Config,
) !void {
    // Get the lambda-build CLI artifact from the dependency
    const cli = lambda_build_dep.artifact("lambda-build");

    // Get configuration options (command-line overrides config defaults)
    const function_name = b.option([]const u8, "function-name", "Function name for Lambda") orelse config.default_function_name;
    const region = b.option([]const u8, "region", "AWS region") orelse null;
    const profile = b.option([]const u8, "profile", "AWS profile") orelse null;
    const role_name = b.option(
        []const u8,
        "role-name",
        "IAM role name (default: lambda_basic_execution)",
    ) orelse config.default_role_name;
    const payload = b.option(
        []const u8,
        "payload",
        "Lambda invocation payload",
    ) orelse "{}";
    const env_file = b.option(
        []const u8,
        "env-file",
        "Path to environment variables file (KEY=VALUE format)",
    ) orelse null;
    const allow_principal = b.option(
        []const u8,
        "allow-principal",
        "AWS service principal to grant invoke permission (e.g., alexa-appkit.amazon.com)",
    ) orelse null;

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
    iam_cmd.addArgs(&.{ "iam", "--role-name", role_name });

    const iam_step = b.step("awslambda_iam", "Create/verify IAM role for Lambda");
    iam_step.dependOn(&iam_cmd.step);

    // Deploy step (depends on package)
    const deploy_cmd = b.addRunArtifact(cli);
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
        "--role-name",
        role_name,
        "--arch",
        arch_str,
    });
    if (env_file) |ef| deploy_cmd.addArgs(&.{ "--env-file", ef });
    if (allow_principal) |ap| deploy_cmd.addArgs(&.{ "--allow-principal", ap });
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
}
