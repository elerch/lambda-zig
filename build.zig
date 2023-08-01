const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    // const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var exe = b.addExecutable(.{
        .name = "custom",
        .root_source_file = .{ .path = "src/sample-main.zig" },
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);

    try lambdaBuildOptions(b, exe);

    // TODO: We can cross-compile of course, but stripping and zip commands
    // may vary
    // TODO: Add test
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
