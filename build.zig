const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Create a module for lambda.zig
    const lambda_module = b.createModule(.{
        .root_source_file = b.path("src/lambda.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "lambda-zig",
        .linkage = .static,
        .root_module = lambda_module,
    });

    // Export the module for other packages to use
    _ = b.addModule("lambda_runtime", .{
        .root_source_file = b.path("src/lambda.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/lambda.zig"),
        .target = target,
        .optimize = optimize,
    });

    const main_tests = b.addTest(.{
        .name = "test",
        .root_module = test_module,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    // Build the lambda-build CLI to ensure it compiles
    // This catches dependency version mismatches between tools/build and the main project
    const lambda_build_dep = b.dependency("lambda_build", .{
        .target = b.graph.host,
        .optimize = optimize,
    });
    const lambda_build_exe = lambda_build_dep.artifact("lambda-build");

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build test`
    // This will evaluate the `test` step rather than the default, which is "install".
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&lambda_build_exe.step);

    // Create executable module
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/sample-main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "custom",
        .root_module = exe_module,
    });

    b.installArtifact(exe);
    try configureBuildInternal(b, exe);
}

/// Internal version of configureBuild for lambda-zig's own build.
///
/// Both this and configureBuild do the same thing, but resolve the lambda_build
/// dependency differently:
///
/// - Here: we call `b.dependency("lambda_build", ...)` directly since `b` is
///   lambda-zig's own Build context, which has lambda_build in its build.zig.zon
///
/// - configureBuild: consumers pass in their lambda_zig dependency, and we use
///   `lambda_zig_dep.builder.dependency("lambda_build", ...)` to resolve it from
///   lambda-zig's build.zig.zon rather than the consumer's
///
/// This avoids requiring consumers to declare lambda_build as a transitive
/// dependency in their own build.zig.zon.
fn configureBuildInternal(b: *std.Build, exe: *std.Build.Step.Compile) !void {
    // When called from lambda-zig's own build, use local dependency
    const lambda_build_dep = b.dependency("lambda_build", .{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    // Ignore return value for internal builds
    _ = try @import("lambdabuild.zig").configureBuild(b, lambda_build_dep, exe, .{});
}

// Re-export types for consumers
const lambdabuild = @import("lambdabuild.zig");

/// Options for Lambda build integration.
pub const Options = lambdabuild.Options;

/// Source for Lambda build configuration (none, file, or inline config).
pub const LambdaConfigSource = lambdabuild.LambdaConfigSource;

/// A config file path with explicit required/optional semantics.
pub const ConfigFile = lambdabuild.ConfigFile;

/// Lambda build configuration struct (role_name, timeout, memory_size, VPC, etc.).
pub const LambdaBuildConfig = lambdabuild.LambdaBuildConfig;

/// Information about the configured Lambda build steps.
pub const BuildInfo = lambdabuild.BuildInfo;

/// Configure Lambda build steps for a Zig project.
///
/// This function adds build steps and options for packaging and deploying
/// Lambda functions to AWS. The `lambda_zig_dep` parameter must be the
/// dependency object obtained from `b.dependency("lambda_zig", ...)`.
///
/// Returns a `LambdaBuildInfo` struct containing:
/// - References to all build steps (package, iam, deploy, invoke)
/// - A `deploy_output` LazyPath to a JSON file with deployment info
/// - The function name used
///
/// ## Build Steps
///
/// The following build steps are added:
///
/// - `awslambda_package`: Package the executable into a Lambda deployment zip
/// - `awslambda_iam`: Create or verify the IAM role for the Lambda function
/// - `awslambda_deploy`: Deploy the function to AWS Lambda (depends on package)
/// - `awslambda_run`: Invoke the deployed function (depends on deploy)
///
/// ## Build Options
///
/// The following command-line options are available:
///
/// - `-Dfunction-name=[string]`: Name of the Lambda function
///        (default: exe.name, or as provided by config parameter)
/// - `-Dregion=[string]`: AWS region for deployment and invocation
/// - `-Dprofile=[string]`: AWS profile to use for credentials
/// - `-Dpayload=[string]`: JSON payload for invocation (default: "{}")
/// - `-Denv-file=[string]`: Path to environment variables file (KEY=VALUE format)
/// - `-Dconfig-file=[string]`: Path to Lambda build config JSON file (overrides function_config)
///
/// ## Configuration File
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
///   "description": "My function description",
///   "allow_principal": "alexa-appkit.amazon.com",
///   "tags": [
///     { "key": "Environment", "value": "production" }
///   ],
///   "logging_config": {
///     "log_format": "JSON",
///     "application_log_level": "INFO"
///   }
/// }
/// ```
///
/// ## Deploy Output
///
/// The `deploy_output` field in the returned struct is a LazyPath to a JSON file
/// containing deployment information (available after deploy completes):
///
/// ```json
/// {
///   "arn": "arn:aws:lambda:us-east-1:123456789012:function:my-function",
///   "function_name": "my-function",
///   "partition": "aws",
///   "region": "us-east-1",
///   "account_id": "123456789012",
///   "role_arn": "arn:aws:iam::123456789012:role/lambda_basic_execution",
///   "architecture": "arm64",
///   "environment_keys": ["MY_VAR"]
/// }
/// ```
///
/// ## Example
///
/// ### Basic Usage (uses lambda.json if present)
///
/// ```zig
/// const lambda_zig = @import("lambda_zig");
///
/// pub fn build(b: *std.Build) !void {
///     const target = b.standardTargetOptions(.{});
///     const optimize = b.standardOptimizeOption(.{});
///
///     const lambda_zig_dep = b.dependency("lambda_zig", .{
///         .target = target,
///         .optimize = optimize,
///     });
///
///     const exe = b.addExecutable(.{ ... });
///     b.installArtifact(exe);
///
///     _ = try lambda_zig.configureBuild(b, lambda_zig_dep, exe, .{});
/// }
/// ```
///
/// ### Inline Configuration
///
/// ```zig
/// _ = try lambda_zig.configureBuild(b, lambda_zig_dep, exe, .{
///     .lambda_config = .{ .config = .{
///         .role_name = "my_custom_role",
///         .timeout = 30,
///         .memory_size = 512,
///         .allow_principal = "alexa-appkit.amazon.com",
///     }},
/// });
/// ```
///
/// ### Custom Config File Path (required by default)
///
/// ```zig
/// _ = try lambda_zig.configureBuild(b, lambda_zig_dep, exe, .{
///     .lambda_config = .{ .file = .{ .path = b.path("deploy/production.json") } },
/// });
/// ```
///
/// ### Optional Config File (silent defaults if missing)
///
/// ```zig
/// _ = try lambda_zig.configureBuild(b, lambda_zig_dep, exe, .{
///     .lambda_config = .{ .file = .{
///         .path = b.path("lambda.json"),
///         .required = false,
///     } },
/// });
/// ```
///
/// ### Dynamically Generated Config
///
/// ```zig
/// const wf = b.addWriteFiles();
/// const config_json = wf.add("lambda-config.json", generated_content);
///
/// _ = try lambda_zig.configureBuild(b, lambda_zig_dep, exe, .{
///     .lambda_config = .{ .file = .{ .path = config_json } },
/// });
/// ```
///
/// ### Using Deploy Output
///
/// ```zig
/// const lambda = try lambda_zig.configureBuild(b, lambda_zig_dep, exe, .{});
///
/// // Use lambda.deploy_output in other steps that need the ARN
/// const my_step = b.addRunArtifact(my_tool);
/// my_step.addFileArg(lambda.deploy_output);
/// my_step.step.dependOn(lambda.deploy_step);  // Ensure deploy runs first
/// ```
pub fn configureBuild(
    b: *std.Build,
    lambda_zig_dep: *std.Build.Dependency,
    exe: *std.Build.Step.Compile,
    options: Options,
) !BuildInfo {
    // Get lambda_build from the lambda_zig dependency's Build context
    const lambda_build_dep = lambda_zig_dep.builder.dependency("lambda_build", .{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    return lambdabuild.configureBuild(b, lambda_build_dep, exe, options);
}
