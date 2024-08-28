const std = @import("std");

const Package = @This();

step: std.Build.Step,
options: Options,

/// This is set as part of the make phase, and is the location in the cache
/// for the lambda package. The package will also be copied to the output
/// directory, but this location makes for a good cache key for deployments
zipfile_cache_dest: ?[]const u8 = null,

zipfile_dest: ?[]const u8 = null,

const base_id: std.Build.Step.Id = .install_file;

pub const Options = struct {
    name: []const u8 = "",
    exe: *std.Build.Step.Compile,
    zipfile_name: []const u8 = "function.zip",
};

pub fn create(owner: *std.Build, options: Options) *Package {
    const name = owner.dupe(options.name);
    const step_name = owner.fmt("{s} {s}{s}", .{
        "aws lambda",
        "package",
        name,
    });
    const package = owner.allocator.create(Package) catch @panic("OOM");
    package.* = .{
        .step = std.Build.Step.init(.{
            .id = base_id,
            .name = step_name,
            .owner = owner,
            .makeFn = make,
        }),
        .options = options,
    };

    return package;
}
pub fn shasumFilePath(self: Package) ![]const u8 {
    return try std.fmt.allocPrint(
        self.step.owner.allocator,
        "{s}{s}{s}",
        .{ std.fs.path.dirname(self.zipfile_cache_dest.?).?, std.fs.path.sep_str, "sha256sum.txt" },
    );
}
pub fn packagedFilePath(self: Package) []const u8 {
    return self.step.owner.getInstallPath(.prefix, self.options.zipfile_name);
}
pub fn packagedFileLazyPath(self: Package) std.Build.LazyPath {
    return .{ .src_path = .{
        .owner = self.step.owner,
        .sub_path = self.step.owner.getInstallPath(.prefix, self.options.zipfile_name),
    } };
}

fn make(step: *std.Build.Step, node: std.Progress.Node) anyerror!void {
    _ = node;
    const self: *Package = @fieldParentPtr("step", step);
    // get a hash of the bootstrap and whatever other files we put into the zip
    // file (because a zip is not really reproducible). That hash becomes the
    // cache directory, similar to the way rest of zig works
    //
    // Otherwise, create the package in our cache indexed by hash, and copy
    // our bootstrap, zip things up and install the file into zig-out
    const bootstrap = bootstrapLocation(self.*) catch |e| {
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        return step.fail("Could not copy output to bootstrap: {}", .{e});
    };
    const bootstrap_dirname = std.fs.path.dirname(bootstrap).?;
    const zipfile_src = try std.fs.path.join(step.owner.allocator, &[_][]const u8{ bootstrap_dirname, self.options.zipfile_name });
    self.zipfile_cache_dest = zipfile_src;
    self.zipfile_dest = self.step.owner.getInstallPath(.prefix, self.options.zipfile_name);
    if (std.fs.copyFileAbsolute(zipfile_src, self.zipfile_dest.?, .{})) |_| {
        // we're good here. The zip file exists in cache and has been copied
        step.result_cached = true;
    } else |_| {
        // error, but this is actually the normal case. We will zip the file
        // using system zip and store that in cache with the output file for later
        // use

        // TODO: For Windows, tar.exe can actually do zip files.
        // tar -a -cf function.zip file1 [file2...]
        //
        // See: https://superuser.com/questions/201371/create-zip-folder-from-the-command-line-windows#comment2725283_898508
        var child = std.process.Child.init(&[_][]const u8{
            "zip",
            "-qj9X",
            zipfile_src,
            bootstrap,
        }, self.step.owner.allocator);
        child.stdout_behavior = .Ignore;
        child.stdin_behavior = .Ignore; // we'll allow stderr through
        switch (try child.spawnAndWait()) {
            .Exited => |rc| if (rc != 0) return step.fail("Non-zero exit code {} from zip", .{rc}),
            .Signal, .Stopped, .Unknown => return step.fail("Abnormal termination from zip step", .{}),
        }

        try std.fs.copyFileAbsolute(zipfile_src, self.zipfile_dest.?, .{}); // It better be there now

        // One last thing. We want to get a Sha256 sum of the zip file, and
        // store it in cache. This will help the deployment process compare
        // to what's out in AWS, since revision id is apparently trash for these
        // purposes
        const zipfile = try std.fs.openFileAbsolute(zipfile_src, .{});
        defer zipfile.close();
        const zip_bytes = try zipfile.readToEndAlloc(step.owner.allocator, 100 * 1024 * 1024);
        var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(zip_bytes, &hash, .{});
        const base64 = std.base64.standard.Encoder;
        var encoded: [base64.calcSize(std.crypto.hash.sha2.Sha256.digest_length)]u8 = undefined;
        const shaoutput = try std.fs.createFileAbsolute(try self.shasumFilePath(), .{});
        defer shaoutput.close();
        try shaoutput.writeAll(base64.encode(encoded[0..], hash[0..]));
    }
}

fn bootstrapLocation(package: Package) ![]const u8 {
    const output = package.step.owner.getInstallPath(.bin, package.options.exe.out_filename);
    // We will always copy the output file, mainly because we also need the hash...
    // if (std.mem.eql(u8, "bootstrap", package.options.exe.out_filename))
    //     return output; // easy path

    // Not so easy...read the file, get a hash of contents, see if it's in cache
    const output_file = try std.fs.openFileAbsolute(output, .{});
    defer output_file.close();
    const output_bytes = try output_file.readToEndAlloc(package.step.owner.allocator, 100 * 1024 * 1024); // 100MB file
    // std.Build.Cache.Hasher
    // std.Buidl.Cache.hasher_init
    var hasher = std.Build.Cache.HashHelper{}; // We'll reuse the same file hasher from cache
    hasher.addBytes(output_bytes);
    const hash = std.fmt.bytesToHex(hasher.hasher.finalResult(), .lower);
    const dest_path = try package.step.owner.cache_root.join(
        package.step.owner.allocator,
        &[_][]const u8{ "p", hash[0..], "bootstrap" },
    );
    const dest_file = std.fs.openFileAbsolute(dest_path, .{}) catch null;
    if (dest_file) |d| {
        d.close();
        return dest_path;
    }
    const pkg_path = try package.step.owner.cache_root.join(
        package.step.owner.allocator,
        &[_][]const u8{"p"},
    );
    // Destination file does not exist. Write the bootstrap (after creating the directory)
    std.fs.makeDirAbsolute(pkg_path) catch |e| {
        std.debug.print("Could not mkdir {?s}: {}\n", .{ std.fs.path.dirname(dest_path), e });
    };
    std.fs.makeDirAbsolute(std.fs.path.dirname(dest_path).?) catch {};
    const write_file = try std.fs.createFileAbsolute(dest_path, .{});
    defer write_file.close();
    try write_file.writeAll(output_bytes);
    return dest_path;
}
