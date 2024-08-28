lambda-zig: A Custom Runtime for AWS Lambda
===========================================

This is a sample custom runtime built in zig (0.13). Simple projects will execute
in <1ms, with a cold start init time of approximately 11ms.

Some custom build steps have been added to build.zig, which will only currently appear if compiling from a linux operating system:

* `zig build awslambda_iam`: Deploy and record a default IAM role for the lambda function
* `zig build awslambda_package`: Package the lambda function for upload
* `zig build awslambda_deploy`: Deploy the lambda function
* `zig build awslambda_run`: Run the lambda function

Custom options:

* **function-name**: set the name of the AWS Lambda function
* **payload**: Use this to set the payload of the function when run using `zig build awslambda_run`
* **region**: Use this to set the region for the function deployment/run
* **function-role**: Name of the role to use for the function. The system will
                     look up the arn from this name, and create if it does not exist
* **function-arn**: Role arn to use with the function. This must exist

The AWS Lambda function can be compiled as a linux x86_64 or linux aarch64
executable. The build script will set the architecture appropriately

Caveats:

* Building on Windows will not yet work, as the package step still uses
  system commands due to the need to create a zip file, and the current lack
  of zip file creation capabilities in the standard library (you can read, but
  not write, zip files with the standard library). A TODO exists with more
  information should you wish to file a PR.

A sample project using this runtime can be found at https://git.lerch.org/lobo/lambda-zig-sample

Using the zig package manager
-----------------------------

The zig package manager [works just fine](https://github.com/ziglang/zig/issues/14279)
in build.zig, which works well for use of this runtime.

To add lambda package/deployment steps to another project:

1. `zig build init-exe`
2. Add a `build.zig.zon` similar to the below
3. Add a line to build.zig to add necessary build options, etc. Not the build function
   return type should be changed from `void` to `!void`

`build.zig`:

```zig
try @import("lambda-zig").lambdaBuildOptions(b, exe);
```

`build.zig.zon`:

```zig
.{
    .name = "lambda-zig",
    .version = "0.1.0",
    .dependencies = .{
        .@"lambda-zig" = .{
            .url = "https://git.lerch.org/lobo/lambda-zig/archive/fa13a08c4d91034a9b19d85f8c4c0af4cedaa67e.tar.gz",
            .hash = "122037c357f834ffddf7b3a514f55edd5a4d7a3cde138a4021b6ac51be8fd2926000",
        },
    },
}
```

That's it! Now you should have the 4 custom build steps
