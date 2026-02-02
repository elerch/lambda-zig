//! Package command - creates a Lambda deployment zip from an executable.
//!
//! The zip file contains a single file named "bootstrap" (Lambda's expected name
//! for custom runtime executables).
//!
//! Note: Uses "store" (uncompressed) format because Zig 0.15's std.compress.flate.Compress
//! has incomplete implementation (drain function panics with TODO). When the compression
//! implementation is completed, this should use deflate level 6.

const std = @import("std");
const zip = std.zip;
const RunOptions = @import("main.zig").RunOptions;

pub fn run(args: []const []const u8, options: RunOptions) !void {
    var exe_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--exe")) {
            i += 1;
            if (i >= args.len) return error.MissingExePath;
            exe_path = args[i];
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) return error.MissingOutputPath;
            output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp(options.stdout);
            try options.stdout.flush();
            return;
        } else {
            try options.stderr.print("Unknown option: {s}\n", .{arg});
            try options.stderr.flush();
            return error.UnknownOption;
        }
    }

    if (exe_path == null) {
        try options.stderr.print("Error: --exe is required\n", .{});
        printHelp(options.stderr);
        try options.stderr.flush();
        return error.MissingExePath;
    }

    if (output_path == null) {
        try options.stderr.print("Error: --output is required\n", .{});
        printHelp(options.stderr);
        try options.stderr.flush();
        return error.MissingOutputPath;
    }

    try createLambdaZip(options.allocator, exe_path.?, output_path.?);

    try options.stdout.print("Created {s}\n", .{output_path.?});
}

fn printHelp(writer: *std.Io.Writer) void {
    writer.print(
        \\Usage: lambda-build package [options]
        \\
        \\Create a Lambda deployment zip from an executable.
        \\
        \\Options:
        \\  --exe <path>        Path to the executable (required)
        \\  --output, -o <path> Output zip file path (required)
        \\  --help, -h          Show this help message
        \\
        \\The executable will be packaged as 'bootstrap' in the zip file,
        \\which is the expected name for Lambda custom runtimes.
        \\
    , .{}) catch {};
}

/// Helper to write a little-endian u16
fn writeU16LE(file: std.fs.File, value: u16) !void {
    const bytes = std.mem.toBytes(std.mem.nativeToLittle(u16, value));
    try file.writeAll(&bytes);
}

/// Helper to write a little-endian u32
fn writeU32LE(file: std.fs.File, value: u32) !void {
    const bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, value));
    try file.writeAll(&bytes);
}

/// Create a Lambda deployment zip file containing a single "bootstrap" executable.
/// Currently uses "store" (uncompressed) format because Zig 0.15's std.compress.flate.Compress
/// has incomplete implementation.
/// TODO: Add deflate compression (level 6) when the Compress implementation is completed.
fn createLambdaZip(allocator: std.mem.Allocator, exe_path: []const u8, output_path: []const u8) !void {
    // Read the executable
    const exe_file = try std.fs.cwd().openFile(exe_path, .{});
    defer exe_file.close();

    const exe_stat = try exe_file.stat();
    const exe_size: u32 = @intCast(exe_stat.size);

    // Allocate buffer and read file contents
    const exe_data = try allocator.alloc(u8, exe_size);
    defer allocator.free(exe_data);
    const bytes_read = try exe_file.readAll(exe_data);
    if (bytes_read != exe_size) return error.IncompleteRead;

    // Calculate CRC32 of uncompressed data
    const crc = std.hash.crc.Crc32IsoHdlc.hash(exe_data);

    // Create the output file
    const out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();

    const filename = "bootstrap";
    const filename_len: u16 = @intCast(filename.len);

    // Reproducible zip files: use fixed timestamp
    // September 26, 1995 at midnight (00:00:00)
    // DOS time format: bits 0-4: seconds/2, bits 5-10: minute, bits 11-15: hour
    // DOS date format: bits 0-4: day, bits 5-8: month, bits 9-15: year-1980
    //
    // Note: We use a fixed timestamp for reproducible builds.
    //
    // If current time is needed in the future:
    // const now = std.time.timestamp();
    // const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now) };
    // const day_secs = epoch_secs.getDaySeconds();
    // const year_day = epoch_secs.getEpochDay().calculateYearDay();
    // const mod_time: u16 = @as(u16, day_secs.getHoursIntoDay()) << 11 |
    //     @as(u16, day_secs.getMinutesIntoHour()) << 5 |
    //     @as(u16, day_secs.getSecondsIntoMinute() / 2);
    // const month_day = year_day.calculateMonthDay();
    // const mod_date: u16 = @as(u16, year_day.year -% 1980) << 9 |
    //     @as(u16, @intFromEnum(month_day.month)) << 5 |
    //     @as(u16, month_day.day_index + 1);

    // 1995-09-26 midnight for reproducible builds
    const mod_time: u16 = 0x0000; // 00:00:00
    const mod_date: u16 = (15 << 9) | (9 << 5) | 26; // 1995-09-26 (year 15 = 1995-1980)

    // Local file header
    try out_file.writeAll(&zip.local_file_header_sig);
    try writeU16LE(out_file, 10); // version needed (1.0 for store)
    try writeU16LE(out_file, 0); // general purpose flags
    try writeU16LE(out_file, @intFromEnum(zip.CompressionMethod.store)); // store (no compression)
    try writeU16LE(out_file, mod_time);
    try writeU16LE(out_file, mod_date);
    try writeU32LE(out_file, crc);
    try writeU32LE(out_file, exe_size); // compressed size = uncompressed for store
    try writeU32LE(out_file, exe_size); // uncompressed size
    try writeU16LE(out_file, filename_len);
    try writeU16LE(out_file, 0); // extra field length
    try out_file.writeAll(filename);

    // File data (uncompressed)
    const local_header_end = 30 + filename_len;
    try out_file.writeAll(exe_data);

    // Central directory file header
    const cd_offset = local_header_end + exe_size;
    try out_file.writeAll(&zip.central_file_header_sig);
    try writeU16LE(out_file, 0x031e); // version made by (Unix, 3.0)
    try writeU16LE(out_file, 10); // version needed (1.0 for store)
    try writeU16LE(out_file, 0); // general purpose flags
    try writeU16LE(out_file, @intFromEnum(zip.CompressionMethod.store)); // store
    try writeU16LE(out_file, mod_time);
    try writeU16LE(out_file, mod_date);
    try writeU32LE(out_file, crc);
    try writeU32LE(out_file, exe_size); // compressed size
    try writeU32LE(out_file, exe_size); // uncompressed size
    try writeU16LE(out_file, filename_len);
    try writeU16LE(out_file, 0); // extra field length
    try writeU16LE(out_file, 0); // file comment length
    try writeU16LE(out_file, 0); // disk number start
    try writeU16LE(out_file, 0); // internal file attributes
    try writeU32LE(out_file, 0o100755 << 16); // external file attributes (Unix executable)
    try writeU32LE(out_file, 0); // relative offset of local header

    try out_file.writeAll(filename);

    // End of central directory record
    const cd_size: u32 = 46 + filename_len;
    try out_file.writeAll(&zip.end_record_sig);
    try writeU16LE(out_file, 0); // disk number
    try writeU16LE(out_file, 0); // disk number with CD
    try writeU16LE(out_file, 1); // number of entries on disk
    try writeU16LE(out_file, 1); // total number of entries
    try writeU32LE(out_file, cd_size); // size of central directory
    try writeU32LE(out_file, cd_offset); // offset of central directory
    try writeU16LE(out_file, 0); // comment length
}

test "create zip with test data" {
    const allocator = std.testing.allocator;

    // Create a temporary test file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_content = "#!/bin/sh\necho hello";
    const test_exe = try tmp_dir.dir.createFile("test_exe", .{});
    try test_exe.writeAll(test_content);
    test_exe.close();

    const exe_path = try tmp_dir.dir.realpathAlloc(allocator, "test_exe");
    defer allocator.free(exe_path);

    const output_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(output_path);

    const full_output = try std.fs.path.join(allocator, &.{ output_path, "test.zip" });
    defer allocator.free(full_output);

    try createLambdaZip(allocator, exe_path, full_output);

    // Verify the zip file can be read by std.zip
    const zip_file = try std.fs.cwd().openFile(full_output, .{});
    defer zip_file.close();

    var read_buffer: [4096]u8 = undefined;
    var file_reader = zip_file.reader(&read_buffer);

    var iter = try zip.Iterator.init(&file_reader);

    // Should have exactly one entry
    const entry = try iter.next();
    try std.testing.expect(entry != null);

    const e = entry.?;

    // Verify filename length is 9 ("bootstrap")
    try std.testing.expectEqual(@as(u32, 9), e.filename_len);

    // Verify compression method is store
    try std.testing.expectEqual(zip.CompressionMethod.store, e.compression_method);

    // Verify sizes match test content
    try std.testing.expectEqual(@as(u64, test_content.len), e.uncompressed_size);
    try std.testing.expectEqual(@as(u64, test_content.len), e.compressed_size);

    // Verify CRC32 matches
    const expected_crc = std.hash.crc.Crc32IsoHdlc.hash(test_content);
    try std.testing.expectEqual(expected_crc, e.crc32);

    // Verify no more entries
    const next_entry = try iter.next();
    try std.testing.expect(next_entry == null);

    // Extract and verify contents
    var extract_dir = std.testing.tmpDir(.{});
    defer extract_dir.cleanup();

    // Reset file reader position
    try file_reader.seekTo(0);

    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
    try e.extract(&file_reader, .{}, &filename_buf, extract_dir.dir);

    // Read extracted file and verify contents
    const extracted = try extract_dir.dir.openFile("bootstrap", .{});
    defer extracted.close();

    var extracted_content: [1024]u8 = undefined;
    const bytes_read = try extracted.readAll(&extracted_content);
    try std.testing.expectEqualStrings(test_content, extracted_content[0..bytes_read]);
}
