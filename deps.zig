const std = @import("std");
pub const pkgs = struct {
    pub const requestz = std.build.Pkg{
        .name = "requestz",
        .path = .{ .path = ".gyro/requestz-ducdetronquito-0.1.1-68845cbcc0c07d54a8cd287ad333ba84/pkg/src/main.zig" },
        .dependencies = &[_]std.build.Pkg{
            std.build.Pkg{
                .name = "http",
                .path = .{ .path = ".gyro/http-ducdetronquito-0.1.3-02dd386aa7452ba02887b98078627854/pkg/src/main.zig" },
            },
            std.build.Pkg{
                .name = "h11",
                .path = .{ .path = ".gyro/h11-ducdetronquito-0.1.1-5d7aa65ac782877d98cc6311a77ca7a8/pkg/src/main.zig" },
                .dependencies = &[_]std.build.Pkg{
                    std.build.Pkg{
                        .name = "http",
                        .path = .{ .path = ".gyro/http-ducdetronquito-0.1.3-02dd386aa7452ba02887b98078627854/pkg/src/main.zig" },
                    },
                },
            },
            std.build.Pkg{
                .name = "iguanaTLS",
                .path = .{ .path = ".gyro/iguanaTLS-alexnask-0d39a361639ad5469f8e4dcdaea35446bbe54b48/pkg/src/main.zig" },
            },
            std.build.Pkg{
                .name = "network",
                .path = .{ .path = ".gyro/zig-network-MasterQ32-b9c91769d8ebd626c8e45b2abb05cbc28ccc50da/pkg/network.zig" },
            },
        },
    };

    pub fn addAllTo(artifact: *std.build.LibExeObjStep) void {
        @setEvalBranchQuota(1_000_000);
        inline for (std.meta.declarations(pkgs)) |decl| {
            if (decl.is_pub and decl.data == .Var) {
                artifact.addPackage(@field(pkgs, decl.name));
            }
        }
    }
};

pub const exports = struct {
};
pub const base_dirs = struct {
    pub const requestz = ".gyro/requestz-ducdetronquito-0.1.1-68845cbcc0c07d54a8cd287ad333ba84/pkg";
};
