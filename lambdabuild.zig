const std = @import("std");
const builtin = @import("builtin");

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
    // The rest of this function is currently reliant on the use of Linux
    // system being used to build the lambda function
    //
    // It is likely that much of this will work on other Unix-like OSs, but
    // we will work this out later
    //
    // TODO: support other host OSs
    if (builtin.os.tag != .linux) return;

    // Package step
    const package_step = b.step("package", "Package the function");
    const function_zip = b.getInstallPath(.bin, "function.zip");

    // TODO: Avoid use of system-installed zip, maybe using something like
    // https://github.com/hdorio/hwzip.zig/blob/master/src/hwzip.zig
    const zip = if (std.mem.eql(u8, "bootstrap", exe.out_filename))
        try std.fmt.allocPrint(b.allocator,
            \\zip -qj9 {s} {s}
        , .{
            function_zip,
            b.getInstallPath(.bin, "bootstrap"),
        })
    else
        // We need to copy stuff around
        try std.fmt.allocPrint(b.allocator,
            \\cp {s} {s} && \
            \\zip -qj9 {s} {s} && \
            \\rm {s}
        , .{
            b.getInstallPath(.bin, exe.out_filename),
            b.getInstallPath(.bin, "bootstrap"),
            function_zip,
            b.getInstallPath(.bin, "bootstrap"),
            b.getInstallPath(.bin, "bootstrap"),
        });
    // std.debug.print("\nzip cmdline: {s}", .{zip});
    defer b.allocator.free(zip);
    var zip_cmd = b.addSystemCommand(&.{ "/bin/sh", "-c", zip });
    zip_cmd.step.dependOn(b.getInstallStep());
    package_step.dependOn(&zip_cmd.step);

    // Deployment
    const deploy_step = b.step("deploy", "Deploy the function");
    var deal_with_iam = true;
    if (b.args) |args| {
        for (args) |arg| {
            if (std.mem.eql(u8, "--role", arg)) {
                deal_with_iam = false;
                break;
            }
        }
    }

    // TODO: Allow custom lambda role names
    var iam_role: []u8 = &.{};
    const iam_step = b.step("iam", "Create/Get IAM role for function");
    deploy_step.dependOn(iam_step); // iam_step will either be a noop or all the stuff below
    if (deal_with_iam) {
        // if someone adds '-- --role arn...' to the command line, we don't
        // need to do anything with the iam role. Otherwise, we'll create/
        // get the IAM role and stick the name in a file in our destination
        // directory to be used later
        const iam_role_name_file = b.getInstallPath(.bin, "iam_role_name");
        iam_role = try std.fmt.allocPrint(b.allocator, "--role $(cat {s})", .{iam_role_name_file});
        // defer b.allocator.free(iam_role);
        if (!fileExists(iam_role_name_file)) {
            // Role get/creation command
            const ifstatement_fmt =
                \\ if aws iam get-role --role-name lambda_basic_execution 2>&1 |grep -q NoSuchEntity; then aws iam create-role --output text --query Role.Arn --role-name lambda_basic_execution --assume-role-policy-document '{
                \\ "Version": "2012-10-17",
                \\ "Statement": [
                \\   {
                \\     "Sid": "",
                \\     "Effect": "Allow",
                \\     "Principal": {
                \\       "Service": "lambda.amazonaws.com"
                \\     },
                \\     "Action": "sts:AssumeRole"
                \\   }
                \\ ]}' > /dev/null; fi && \
                \\ aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/AWSLambdaExecute --role-name lambda_basic_execution && \
                \\ aws iam get-role --role-name lambda_basic_execution --query Role.Arn --output text > 
            ;

            const ifstatement = try std.mem.concat(b.allocator, u8, &[_][]const u8{ ifstatement_fmt, iam_role_name_file });
            defer b.allocator.free(ifstatement);
            iam_step.dependOn(&b.addSystemCommand(&.{ "/bin/sh", "-c", ifstatement }).step);
        }
    }
    const function_name = b.option([]const u8, "function-name", "Function name for Lambda [zig-fn]") orelse "zig-fn";
    const function_name_file = b.getInstallPath(.bin, function_name);
    const ifstatement = "if [ ! -f {s} ] || [ {s} -nt {s} ]; then if aws lambda get-function --function-name {s} 2>&1 |grep -q ResourceNotFoundException; then echo not found > /dev/null; {s}; else echo found > /dev/null; {s}; fi; fi";
    // The architectures option was introduced in 2.2.43 released 2021-10-01
    // We want to use arm64 here because it is both faster and cheaper for most
    // Amazon Linux 2 is the only arm64 supported option
    const not_found = "aws lambda create-function --architectures arm64 --runtime provided.al2 --function-name {s} --zip-file fileb://{s} --handler not_applicable {s} && touch {s}";
    const not_found_fmt = try std.fmt.allocPrint(b.allocator, not_found, .{ function_name, function_zip, iam_role, function_name_file });
    defer b.allocator.free(not_found_fmt);
    const found = "aws lambda update-function-code --function-name {s} --zip-file fileb://{s} && touch {s}";
    const found_fmt = try std.fmt.allocPrint(b.allocator, found, .{ function_name, function_zip, function_name_file });
    defer b.allocator.free(found_fmt);
    var found_final: []const u8 = undefined;
    var not_found_final: []const u8 = undefined;
    if (b.args) |args| {
        found_final = try addArgs(b.allocator, found_fmt, args);
        not_found_final = try addArgs(b.allocator, not_found_fmt, args);
    } else {
        found_final = found_fmt;
        not_found_final = not_found_fmt;
    }
    const cmd = try std.fmt.allocPrint(b.allocator, ifstatement, .{
        function_name_file,
        std.fs.path.dirname(exe.root_src.?.path).?,
        function_name_file,
        function_name,
        not_found_fmt,
        found_fmt,
    });

    defer b.allocator.free(cmd);

    // std.debug.print("{s}\n", .{cmd});
    deploy_step.dependOn(package_step);
    deploy_step.dependOn(&b.addSystemCommand(&.{ "/bin/sh", "-c", cmd }).step);

    // TODO: Looks like IquanaTLS isn't playing nicely with payloads this small
    // const payload = b.option([]const u8, "payload", "Lambda payload [{\"foo\":\"bar\"}]") orelse
    //     \\ {"foo": "bar"}"
    // ;
    const payload = b.option([]const u8, "payload", "Lambda payload [{\"foo\":\"bar\", \"baz\": \"qux\"}]") orelse
        \\ {"foo": "bar", "baz": "qux"}"
    ;

    const run_script =
        \\ f=$(mktemp) && \
        \\ logs=$(aws lambda invoke \
        \\          --cli-binary-format raw-in-base64-out \
        \\          --invocation-type RequestResponse \
        \\          --function-name {s} \
        \\          --payload '{s}' \
        \\          --log-type Tail \
        \\          --query LogResult \
        \\          --output text "$f"  |base64 -d) && \
        \\  cat "$f" && rm "$f" && \
        \\  echo && echo && echo "$logs"
    ;
    const run_script_fmt = try std.fmt.allocPrint(b.allocator, run_script, .{ function_name, payload });
    defer b.allocator.free(run_script_fmt);
    const run_cmd = b.addSystemCommand(&.{ "/bin/sh", "-c", run_script_fmt });
    run_cmd.step.dependOn(deploy_step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("remoterun", "Run the app in AWS lambda");
    run_step.dependOn(&run_cmd.step);
}
