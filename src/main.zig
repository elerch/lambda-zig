const std = @import("std");
const lambda = @import("lambda.zig");

// zig package -Drelease-safe does the following:
//
// zig build -Drelease-safe
// strip zig-out/bin/bootstrap # should this be stripped?
// zip -j9 zig-out/bin/function.zip zig-out/bin/bootstrap
//
// zig deploy will also do something like:
//
// aws lambda update-function-code --function-name zig-test --zip-file fileb://function.zip
pub fn main() anyerror!void {
    try lambda.run(handler);
}

fn handler(allocator: *std.mem.Allocator, event_data: []const u8) ![]const u8 {
    _ = allocator;
    return event_data;
}
