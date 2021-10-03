lambda-zig: A Custom Runtime for AWS Lambda
===========================================

This is a sample custom runtime built in zig. Simple projects will execute
in <1ms, with a cold start init time of approximately 11ms.

Some custom build steps have been added to build.zig:

* `zig build iam`: Deploy and record a default IAM role for the lambda function
* `zig build package`: Package the lambda function for upload
* `zig build deploy`: Deploy the lambda function
* `zig build run`: Run the lambda function

Custom options:

* **debug**: boolean flag to avoid the debug symbols to be stripped. Useful to see
  error return traces in the AWS Lambda logs
* **function-name**: set the name of the AWS Lambda function
* **payload**: Use this to set the payload of the function when run using `zig build run`

Additionally, a custom IAM role can be used for the function by appending ``-- --role myawesomerole``
to the `zig build deploy` command. This has not really been tested. The role name
is cached in zig-out/bin/iam_role_name, so you can also just set that to the full
arn of your iam role if you'd like.

The AWS Lambda function is compiled as a linux ARM64 executable. Since the build.zig
calls out to the shell for AWS operations, you will need AWS CLI v2.2.43 or greater.

This project vendors dependencies with [gyro](https://github.com/mattnite/gyro), so 
first time build should be done with `gyro build`. This should be working
on zig master - certain build.zig constructs are not available in zig 0.8.1.


Caveats:

* Small inbound lambda payloads seem to be confusing [requestz](https://github.com/ducdetronquito/requestz),
  which just never returns, causing timeouts
* Unhandled invocation errors seem to be causing the same problem
