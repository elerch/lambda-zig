const std = @import("std");

specified_region: ?[]const u8,
allocator: std.mem.Allocator,
/// internal state, please do not use
_calculated_region: ?[]const u8 = null,
const Region = @This();
pub fn region(self: *Region) ![]const u8 {
    if (self.specified_region) |r| return r; // user specified
    if (self._calculated_region) |r| return r; // cached
    self._calculated_region = try findRegionFromSystem(self.allocator);
    return self._calculated_region.?;
}

// AWS_CONFIG_FILE (default is ~/.aws/config
// AWS_DEFAULT_REGION
fn findRegionFromSystem(allocator: std.mem.Allocator) ![]const u8 {
    const env_map = try std.process.getEnvMap(allocator);
    if (env_map.get("AWS_DEFAULT_REGION")) |r| return r;
    const config_file_path = env_map.get("AWS_CONFIG_FILE") orelse
        try std.fs.path.join(allocator, &[_][]const u8{
        env_map.get("HOME") orelse env_map.get("USERPROFILE").?,
        ".aws",
        "config",
    });
    const config_file = try std.fs.openFileAbsolute(config_file_path, .{});
    defer config_file.close();
    const config_bytes = try config_file.readToEndAlloc(allocator, 1024 * 1024);
    const profile = env_map.get("AWS_PROFILE") orelse "default";
    var line_iterator = std.mem.split(u8, config_bytes, "\n");
    var in_profile = false;
    while (line_iterator.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (!in_profile) {
            if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                // this is a profile directive!
                // std.debug.print("profile: {s}, in file: {s}\n", .{ profile, trimmed[1 .. trimmed.len - 1] });
                if (std.mem.eql(u8, profile, trimmed[1 .. trimmed.len - 1])) {
                    in_profile = true;
                }
            }
            continue; // we're only looking for a profile at this point
        }
        // look for our region directive
        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']')
            return error.RegionNotFound; // we've hit another profile without getting our region
        if (!std.mem.startsWith(u8, trimmed, "region")) continue;
        var equalityiterator = std.mem.split(u8, trimmed, "=");
        _ = equalityiterator.next() orelse return error.RegionNotFound;
        const raw_val = equalityiterator.next() orelse return error.RegionNotFound;
        return try allocator.dupe(u8, std.mem.trimLeft(u8, raw_val, " \t"));
    }
    return error.RegionNotFound;
}
