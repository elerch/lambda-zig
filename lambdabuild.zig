const std = @import("std");
const builtin = @import("builtin");
const Package = @import("lambdabuild/Package.zig");
const Iam = @import("lambdabuild/Iam.zig");
const Deploy = @import("lambdabuild/Deploy.zig");
const Invoke = @import("lambdabuild/Invoke.zig");

fn fileExists(file_name: []const u8) bool {
    const file = std.fs.openFileAbsolute(file_name, .{}) catch return false;
    defer file.close();
    return true;
}
fn addArgs(allocator: std.mem.Allocator, original: []const u8, args: [][]const u8) ![]const u8 {
    var rc = original;
    for (args) |arg| {
        rc = try std.mem.concat(allocator, u8, &.{ rc, " ", arg });
    }
    return rc;
}

/// lambdaBuildSteps will add four build steps to the build (if compiling
/// the code on a Linux host):
///
/// * awslambda_package:   Packages the function for deployment to Lambda
///                        (dependencies are the zip executable and a shell)
/// * awslambda_iam:       Gets an IAM role for the Lambda function, and creates it if it does not exist
///                        (dependencies are the AWS CLI, grep and a shell)
/// * awslambda_deploy:    Deploys the lambda function to a live AWS environment
///                        (dependencies are the AWS CLI, and a shell)
/// * awslambda_run:       Runs the lambda function in a live AWS environment
///                        (dependencies are the AWS CLI, and a shell)
///
/// awslambda_run depends on deploy
/// awslambda_deploy depends on iam and package
///
/// iam and package do not have any dependencies
pub fn configureBuild(b: *std.Build, exe: *std.Build.Step.Compile, function_name: []const u8) !void {
    // The rest of this function is currently reliant on the use of Linux
    // system being used to build the lambda function
    //
    // It is likely that much of this will work on other Unix-like OSs, but
    // we will work this out later
    //
    // TODO: support other host OSs
    if (builtin.os.tag != .linux) return;

    @import("aws").aws.globalLogControl(.info, .warn, .info, false);
    const package_step = Package.create(b, .{ .exe = exe });

    const step = b.step("awslambda_package", "Package the function");
    step.dependOn(&package_step.step);
    package_step.step.dependOn(b.getInstallStep());

    // Doing this will require that the aws dependency be added to the downstream
    // build.zig.zon
    // const lambdabuild = b.addExecutable(.{
    //     .name = "lambdabuild",
    //     .root_source_file = .{
    //         // we use cwd_relative here because we need to compile this relative
    //         // to whatever directory this file happens to be. That is likely
    //         // in a cache directory, not the base of the build.
    //         .cwd_relative = try std.fs.path.join(b.allocator, &[_][]const u8{
    //             std.fs.path.dirname(@src().file).?,
    //             "lambdabuild/src/main.zig",
    //         }),
    //     },
    //     .target = b.host,
    // });
    // const aws_dep = b.dependency("aws", .{
    //     .target = b.host,
    //     .optimize = lambdabuild.root_module.optimize orelse .Debug,
    // });
    // const aws_module = aws_dep.module("aws");
    // lambdabuild.root_module.addImport("aws", aws_module);
    //

    const iam_role_name = b.option(
        []const u8,
        "function-role",
        "IAM role name for function (will create if it does not exist) [lambda_basic_execution]",
    ) orelse "lambda_basic_execution_blah2";

    const iam_role_arn = b.option(
        []const u8,
        "function-arn",
        "Preexisting IAM role arn for function",
    );

    const iam = Iam.create(b, .{
        .role_name = iam_role_name,
        .role_arn = iam_role_arn,
    });
    const iam_step = b.step("awslambda_iam", "Create/Get IAM role for function");
    iam_step.dependOn(&iam.step);

    const region = try b.allocator.create(@import("lambdabuild/Region.zig"));
    region.* = .{
        .allocator = b.allocator,
        .specified_region = b.option([]const u8, "region", "Region to use [default is autodetect from environment/config]"),
    };

    // Deployment
    const deploy = Deploy.create(b, .{
        .name = function_name,
        .arch = exe.root_module.resolved_target.?.result.cpu.arch,
        .iam_step = iam,
        .package_step = package_step,
        .region = region,
    });

    const deploy_step = b.step("awslambda_deploy", "Deploy the function");
    deploy_step.dependOn(&deploy.step);

    const payload = b.option([]const u8, "payload", "Lambda payload [{\"foo\":\"bar\", \"baz\": \"qux\"}]") orelse
        \\ {"foo": "bar", "baz": "qux"}"
    ;

    const invoke = Invoke.create(b, .{
        .name = function_name,
        .payload = payload,
        .region = region,
    });
    invoke.step.dependOn(&deploy.step);
    const run_step = b.step("awslambda_run", "Run the app in AWS lambda");
    run_step.dependOn(&invoke.step);
}

// AWS_CONFIG_FILE (default is ~/.aws/config
// AWS_DEFAULT_REGION
fn findRegionFromSystem(allocator: std.mem.Allocator) ![]const u8 {
    const env_map = try std.process.getEnvMap(allocator);
    if (env_map.get("AWS_DEFAULT_REGION")) |r| return r;
    const config_file_path = env_map.get("AWS_CONFIG_FILE") orelse
        try std.fs.path.join(allocator, &[_][]const u8{
        env_map.get("HOME") orelse env_map.get("USERPROFILE").?,
        ".aws",
        "config",
    });
    const config_file = try std.fs.openFileAbsolute(config_file_path, .{});
    defer config_file.close();
    const config_bytes = try config_file.readToEndAlloc(allocator, 1024 * 1024);
    const profile = env_map.get("AWS_PROFILE") orelse "default";
    var line_iterator = std.mem.split(u8, config_bytes, "\n");
    var in_profile = false;
    while (line_iterator.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (!in_profile) {
            if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                // this is a profile directive!
                // std.debug.print("profile: {s}, in file: {s}\n", .{ profile, trimmed[1 .. trimmed.len - 1] });
                if (std.mem.eql(u8, profile, trimmed[1 .. trimmed.len - 1])) {
                    in_profile = true;
                }
            }
            continue; // we're only looking for a profile at this point
        }
        // look for our region directive
        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']')
            return error.RegionNotFound; // we've hit another profile without getting our region
        if (!std.mem.startsWith(u8, trimmed, "region")) continue;
        var equalityiterator = std.mem.split(u8, trimmed, "=");
        _ = equalityiterator.next() orelse return error.RegionNotFound;
        const raw_val = equalityiterator.next() orelse return error.RegionNotFound;
        return try allocator.dupe(u8, std.mem.trimLeft(u8, raw_val, " \t"));
    }
    return error.RegionNotFound;
}
