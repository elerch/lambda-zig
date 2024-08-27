const std = @import("std");

const Package = @This();

step: std.Build.Step,
lambda_zipfile: []const u8,

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
        .lambda_zipfile = options.zipfile_name,
    };

    // TODO: For Windows, tar.exe can actually do zip files. tar -a -cf function.zip file1 [file2...]
    // https://superuser.com/questions/201371/create-zip-folder-from-the-command-line-windows#comment2725283_898508
    //
    // We'll want two system commands here. One for the exe itself, and one for
    // other files (TODO: what does this latter one look like? maybe it's an option?)
    var zip_cmd = owner.addSystemCommand(&.{ "zip", "-qj9X" });
    zip_cmd.has_side_effects = true; // TODO: move these to makeFn as we have little cache control here...
    zip_cmd.setCwd(.{ .src_path = .{
        .owner = owner,
        .sub_path = owner.getInstallPath(.prefix, "."),
    } });
    const zipfile = zip_cmd.addOutputFileArg(options.zipfile_name);
    zip_cmd.addArg(owner.getInstallPath(.bin, "bootstrap"));
    // std.debug.print("\nzip cmdline: {s}", .{zip});
    if (!std.mem.eql(u8, "bootstrap", options.exe.out_filename)) {
        // We need to copy stuff around
        // TODO: should this be installing bootstrap binary in .bin directory?
        const cp_cmd = owner.addSystemCommand(&.{ "cp", owner.getInstallPath(.bin, options.exe.out_filename) });
        cp_cmd.has_side_effects = true;
        const copy_output = cp_cmd.addOutputFileArg("bootstrap");
        const install_copy = owner.addInstallFileWithDir(copy_output, .bin, "bootstrap");
        cp_cmd.step.dependOn(owner.getInstallStep());
        zip_cmd.step.dependOn(&install_copy.step);
        // might as well leave this bootstrap around for caching purposes
        // const rm_cmd = owner.addSystemCommand(&.{ "rm", owner.getInstallPath(.bin, "bootstrap"), });
    }
    const install_zipfile = owner.addInstallFileWithDir(zipfile, .prefix, options.zipfile_name);
    install_zipfile.step.dependOn(&zip_cmd.step);
    package.step.dependOn(&install_zipfile.step);
    return package;
}

pub fn packagedFilePath(self: Package) []const u8 {
    return self.step.owner.getInstallPath(.prefix, self.options.zipfile_name);
}
pub fn packagedFileLazyPath(self: Package) std.Build.LazyPath {
    return .{ .src_path = .{
        .owner = self.step.owner,
        .sub_path = self.step.owner.getInstallPath(.prefix, self.lambda_zipfile),
    } };
}

fn make(step: *std.Build.Step, node: std.Progress.Node) anyerror!void {
    // Make here doesn't actually do anything. But we want to set up this
    // step this way, so that when (if) zig stdlib gains the abiltity to write
    // zip files in addition to reading them, we can skip all the system commands
    // and just do all the things here instead
    //
    //
    // TODO: The caching plan will be:
    //
    // get a hash of the bootstrap and whatever other files we put into the zip
    // file (because a zip is not really reproducible). If the cache directory
    // has the hash as its latest hash, we have nothing to do, so we can exit
    // at that point
    //
    // Otherwise, store that hash in our cache, and copy our bootstrap, zip
    // things up and install the file into zig-out
    _ = node;
    _ = step;
}
