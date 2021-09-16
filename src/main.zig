const std = @import("std");
const requestz = @import("requestz");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;

    var client = try requestz.Client.init(allocator);
    defer client.deinit();

    var response = try client.get("http://httpbin.org/get", .{});
    std.log.info("{s}", .{response.body});
    defer response.deinit();
}
