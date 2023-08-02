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

    const lib = b.addStaticLibrary(.{
        .name = "lambda-zig",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/lambda.zig" },
        .target = target,
        .optimize = optimize,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/lambda.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build test`
    // This will evaluate the `test` step rather than the default, which is "install".
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    var exe = b.addExecutable(.{
        .name = "custom",
        .root_source_file = .{ .path = "src/sample-main.zig" },
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);
    try lambdaBuildOptions(b, exe);
}

/// lambdaBuildOptions will add three build options to the build (if compiling
/// the code on a Linux host):
///
/// * package:   Packages the function for deployment to Lambda
///              (dependencies are the zip executable and a shell)
/// * iam:       Gets an IAM role for the Lambda function, and creates it if it does not exist
///              (dependencies are the AWS CLI, grep and a shell)
/// * deploy:    Deploys the lambda function to a live AWS environment
///              (dependencies are the AWS CLI, and a shell)
/// * remoterun: Runs the lambda function in a live AWS environment
///              (dependencies are the AWS CLI, and a shell)
///
/// remoterun depends on deploy
/// deploy depends on iam and package
///
/// iam and package do not have any dependencies
pub fn lambdaBuildOptions(b: *std.build.Builder, exe: *std.Build.Step.Compile) !void {
    try @import("lambdabuild.zig").lambdaBuildOptions(b, exe);
}
