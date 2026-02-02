const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the main module for the CLI
    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add aws dependency to the module
    const aws_dep = b.dependency("aws", .{ .target = target, .optimize = optimize });
    main_module.addImport("aws", aws_dep.module("aws"));

    const exe = b.addExecutable(.{
        .name = "lambda-build",
        .root_module = main_module,
    });

    b.installArtifact(exe);

    // Run step for testing: zig build run -- package --exe /path/to/exe --output /path/to/out.zip
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args|
        run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the CLI");
    run_step.dependOn(&run_cmd.step);

    // Test step
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("aws", aws_dep.module("aws"));

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
