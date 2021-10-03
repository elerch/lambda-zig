const builtin = @import("builtin");
const std = @import("std");
const pkgs = @import("deps.zig").pkgs;

pub fn build(b: *std.build.Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    // We want the target to be aarch64-linux for deploys
    const target = std.zig.CrossTarget{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
    };

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    // const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("bootstrap", "src/main.zig");

    pkgs.addAllTo(exe);
    exe.setTarget(target);
    exe.setBuildMode(.ReleaseSafe);
    exe.strip = true;
    exe.install();

    // TODO: We can cross-compile of course, but stripping and zip commands
    // may vary
    if (std.builtin.os.tag == .linux) {
        // Package step
        const package_step = b.step("package", "Package the function");
        package_step.dependOn(b.getInstallStep());
        // strip may not be installed or work for the target arch
        // TODO: make this much less fragile
        const strip = try std.fmt.allocPrint(b.allocator, "[ -x /usr/aarch64-linux-gnu/bin/strip ] && /usr/aarch64-linux-gnu/bin/strip {s}", .{b.getInstallPath(exe.install_step.?.dest_dir, exe.install_step.?.artifact.out_filename)});
        defer b.allocator.free(strip);
        package_step.dependOn(&b.addSystemCommand(&.{ "/bin/sh", "-c", strip }).step);
        const function_zip = b.getInstallPath(exe.install_step.?.dest_dir, "function.zip");
        const zip = try std.fmt.allocPrint(b.allocator, "zip -qj9 {s} {s}", .{ function_zip, b.getInstallPath(exe.install_step.?.dest_dir, exe.install_step.?.artifact.out_filename) });
        defer b.allocator.free(zip);
        package_step.dependOn(&b.addSystemCommand(&.{ "/bin/sh", "-c", zip }).step);

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
        var iam_role: []u8 = &.{};
        const iam_step = b.step("iam", "Create/Get IAM role for function");
        deploy_step.dependOn(iam_step); // iam_step will either be a noop or all the stuff below
        if (deal_with_iam) {
            // if someone adds '-- --role arn...' to the command line, we don't
            // need to do anything with the iam role. Otherwise, we'll create/
            // get the IAM role and stick the name in a file in our destination
            // directory to be used later
            const iam_role_name_file = b.getInstallPath(exe.install_step.?.dest_dir, "iam_role_name");
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
        const function_name_file = b.getInstallPath(exe.install_step.?.dest_dir, function_name);
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
            std.fs.path.dirname(exe.root_src.?.path),
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

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }
}
fn fileExists(file_name: []const u8) bool {
    const file = std.fs.openFileAbsolute(file_name, .{}) catch return false;
    defer file.close();
    return true;
}
fn addArgs(allocator: *std.mem.Allocator, original: []const u8, args: [][]const u8) ![]const u8 {
    var rc = original;
    for (args) |arg| {
        rc = try std.mem.concat(allocator, u8, &.{ rc, " ", arg });
    }
    return rc;
}
