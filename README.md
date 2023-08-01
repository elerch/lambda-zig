lambda-zig: A Custom Runtime for AWS Lambda
===========================================

This is a sample custom runtime built in zig. Simple projects will execute
in <1ms, with a cold start init time of approximately 11ms.

Some custom build steps have been added to build.zig, which will only currently appear if compiling from a linux operating system:

* `zig build iam`: Deploy and record a default IAM role for the lambda function
* `zig build package`: Package the lambda function for upload
* `zig build deploy`: Deploy the lambda function
* `zig build remoterun`: Run the lambda function

Custom options:

* **function-name**: set the name of the AWS Lambda function
* **payload**: Use this to set the payload of the function when run using `zig build remoterun`

Additionally, a custom IAM role can be used for the function by appending ``-- --role myawesomerole``
to the `zig build deploy` command. This has not really been tested. The role name
is cached in zig-out/bin/iam_role_name, so you can also just set that to the full
arn of your iam role if you'd like.

The AWS Lambda function is compiled as a linux ARM64 executable. Since the build.zig
calls out to the shell for AWS operations, you will need the AWS CLI. v2.2.43 has been tested.

Caveats:

* Unhandled invocation errors seem to be causing timeouts
* This has been upgraded to zig version 0.11.0-dev.3886+0c1bfe271 and relies on
  features introduced January 12th 2023. I intend to make it compatible with
  zig 0.11 on its release in August 2023
* zig build options only appear if compiling using linux, although it should be trivial
  to make it work on other Unix-like operating systems (e.g. macos, freebsd). In fact,
  it will likely work with just a change to the operating system check
* There are a **ton** of TODO's in this code. Current state is more of a proof of
  concept. PRs are welcome!

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
