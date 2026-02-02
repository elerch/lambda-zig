lambda-zig: A Custom Runtime for AWS Lambda
===========================================

This is a custom runtime built in Zig (0.15). Simple projects will
execute in <1ms, with a cold start init time of approximately 11ms.

Custom build steps are available for packaging and deploying Lambda functions:

* `zig build awslambda_package`: Package the Lambda function into a zip file
* `zig build awslambda_iam`: Create or verify IAM role for the Lambda function
* `zig build awslambda_deploy`: Deploy the Lambda function to AWS
* `zig build awslambda_run`: Invoke the deployed Lambda function

Build options:

* **function-name**: Name of the AWS Lambda function
* **payload**: JSON payload for function invocation (used with awslambda_run)
* **region**: AWS region for deployment and invocation
* **profile**: AWS profile to use for credentials
* **role-name**: IAM role name for the function (default: lambda_basic_execution)

The Lambda function can be compiled for x86_64 or aarch64. The build system
automatically configures the Lambda architecture based on the target.

A sample project using this runtime can be found at
https://git.lerch.org/lobo/lambda-zig-sample

Using the Zig Package Manager
-----------------------------

To add Lambda package/deployment steps to another project:

1. Fetch the dependency:

```sh
zig fetch --save git+https://git.lerch.org/lobo/lambda-zig
```

2. Update your `build.zig`:

```zig
const std = @import("std");
const lambda_zig = @import("lambda_zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get lambda-zig dependency
    const lambda_zig_dep = b.dependency("lambda_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add lambda runtime to your module
    exe_module.addImport("aws_lambda_runtime", lambda_zig_dep.module("lambda_runtime"));

    const exe = b.addExecutable(.{
        .name = "bootstrap",
        .root_module = exe_module,
    });

    b.installArtifact(exe);

    // Add Lambda build steps
    try lambda_zig.configureBuild(b, lambda_zig_dep, exe);
}
```

Note: The build function return type must be `!void` or catch/deal with errors
to support the Lambda build integration.
