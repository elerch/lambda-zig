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
* **env-file**: Path to environment variables file for the Lambda function
* **config-file**: Path to lambda.json configuration file (overrides build.zig settings)

The Lambda function can be compiled for x86_64 or aarch64. The build system
automatically configures the Lambda architecture based on the target.

A sample project using this runtime can be found at
https://git.lerch.org/lobo/lambda-zig-sample

Lambda Configuration
--------------------

Lambda functions can be configured via a `lambda.json` file or inline in `build.zig`.
The configuration controls IAM roles, function settings, and deployment options.

### Configuration File (lambda.json)

By default, the build system looks for an optional `lambda.json` file in your project root.
If found, it will use these settings for deployment.

```json
{
  "role_name": "my_lambda_role",
  "timeout": 30,
  "memory_size": 512,
  "description": "My Lambda function",
  "allow_principal": "alexa-appkit.amazon.com",
  "tags": [
    { "key": "Environment", "value": "production" },
    { "key": "Project", "value": "my-project" }
  ]
}
```

### Available Configuration Options

Many of these configuration options are from the Lambda [CreateFunction](https://docs.aws.amazon.com/lambda/latest/api/API_CreateFunction.html#API_CreateFunction_RequestBody)
API call and more details are available there.


| Option               | Type     | Default                    | Description                                 |
|----------------------|----------|----------------------------|---------------------------------------------|
| `role_name`          | string   | `"lambda_basic_execution"` | IAM role name for the function              |
| `timeout`            | integer  | AWS default (3)            | Execution timeout in seconds (1-900)        |
| `memory_size`        | integer  | AWS default (128)          | Memory allocation in MB (128-10240)         |
| `description`        | string   | null                       | Human-readable function description         |
| `allow_principal`    | string   | null                       | AWS service principal for invoke permission |
| `kmskey_arn`         | string   | null                       | KMS key ARN for environment encryption      |
| `layers`             | string[] | null                       | Lambda layer ARNs to attach                 |
| `tags`               | Tag[]    | null                       | Resource tags (array of `{key, value}`)     |
| `vpc_config`         | object   | null                       | VPC configuration (see below)               |
| `dead_letter_config` | object   | null                       | Dead letter queue configuration             |
| `tracing_config`     | object   | null                       | X-Ray tracing configuration                 |
| `ephemeral_storage`  | object   | AWS default (512)          | Ephemeral storage configuration             |
| `logging_config`     | object   | null                       | CloudWatch logging configuration            |

### VPC Configuration

```json
{
  "vpc_config": {
    "subnet_ids": ["subnet-12345", "subnet-67890"],
    "security_group_ids": ["sg-12345"],
    "ipv6_allowed_for_dual_stack": false
  }
}
```

### Tracing Configuration

```json
{
  "tracing_config": {
    "mode": "Active"
  }
}
```

Mode must be `"Active"` or `"PassThrough"`.

### Logging Configuration

```json
{
  "logging_config": {
    "log_format": "JSON",
    "application_log_level": "INFO",
    "system_log_level": "WARN",
    "log_group": "/aws/lambda/my-function"
  }
}
```

Log format must be `"JSON"` or `"Text"`.

### Ephemeral Storage

```json
{
  "ephemeral_storage": {
    "size": 512
  }
}
```

Size must be between 512-10240 MB.

### Dead Letter Configuration

```json
{
  "dead_letter_config": {
    "target_arn": "arn:aws:sqs:us-east-1:123456789:my-dlq"
  }
}
```

### Build Integration Options

You can also configure Lambda settings directly in `build.zig`:

```zig
// Use a specific config file (required - fails if missing)
_ = try lambda.configureBuild(b, dep, exe, .{
    .lambda_config = .{ .file = .{
        .path = b.path("deploy/lambda.json"),
        .required = true,
    }},
});

// Use inline configuration
_ = try lambda.configureBuild(b, dep, exe, .{
    .lambda_config = .{ .config = .{
        .role_name = "my_role",
        .timeout = 30,
        .memory_size = 512,
        .description = "My function",
    }},
});

// Disable config file lookup entirely
_ = try lambda.configureBuild(b, dep, exe, .{
    .lambda_config = .none,
});
```

### Overriding Config at Build Time

The `-Dconfig-file` build option overrides the `build.zig` configuration:

```sh
# Use a different config file for staging
zig build awslambda_deploy -Dconfig-file=lambda-staging.json

# Use production config
zig build awslambda_deploy -Dconfig-file=deploy/lambda-prod.json
```

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

### Using lambda.json (Recommended)

Add `allow_principal` to your configuration file:

```json
{
  "allow_principal": "alexa-appkit.amazon.com"
}
```

Common service principals:
- `alexa-appkit.amazon.com` - Alexa Skills Kit
- `apigateway.amazonaws.com` - API Gateway
- `s3.amazonaws.com` - S3 event notifications
- `events.amazonaws.com` - EventBridge/CloudWatch Events

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
