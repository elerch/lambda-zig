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
* **env-file**: Path to environment variables file for the Lambda function
* **allow-principal**: AWS service principal to grant invoke permission (e.g., alexa-appkit.amazon.com)

The Lambda function can be compiled for x86_64 or aarch64. The build system
automatically configures the Lambda architecture based on the target.

A sample project using this runtime can be found at
https://git.lerch.org/lobo/lambda-zig-sample

Environment Variables
---------------------

Lambda functions can be configured with environment variables during deployment.
This is useful for passing configuration, secrets, or credentials to your function.

### Using the build system

Pass the `-Denv-file` option to specify a file containing environment variables:

```sh
zig build awslambda_deploy -Dfunction-name=my-function -Denv-file=.env
```

### Using the CLI directly

The `lambda-build` CLI supports both `--env` flags and `--env-file`:

```sh
# Set individual variables
./lambda-build deploy --function-name my-fn --zip-file function.zip \
    --env DB_HOST=localhost --env DB_PORT=5432

# Load from file
./lambda-build deploy --function-name my-fn --zip-file function.zip \
    --env-file .env

# Combine both (--env values override --env-file)
./lambda-build deploy --function-name my-fn --zip-file function.zip \
    --env-file .env --env DEBUG=true
```

### Environment file format

The environment file uses a simple `KEY=VALUE` format, one variable per line:

```sh
# Database configuration
DB_HOST=localhost
DB_PORT=5432

# API keys
API_KEY=secret123
```

Lines starting with `#` are treated as comments. Empty lines are ignored.

Service Permissions
-------------------

Lambda functions can be configured to allow invocation by AWS service principals.
This is required for services like Alexa Skills Kit, API Gateway, or S3 to trigger
your Lambda function.

### Using the build system

Pass the `-Dallow-principal` option to grant invoke permission to a service:

```sh
# Allow Alexa Skills Kit to invoke the function
zig build awslambda_deploy -Dfunction-name=my-skill -Dallow-principal=alexa-appkit.amazon.com

# Allow API Gateway to invoke the function
zig build awslambda_deploy -Dfunction-name=my-api -Dallow-principal=apigateway.amazonaws.com
```

### Using the CLI directly

```sh
./lambda-build deploy --function-name my-fn --zip-file function.zip \
    --allow-principal alexa-appkit.amazon.com
```

The permission is idempotent - if it already exists, the deployment will continue
successfully.

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
