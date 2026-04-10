const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const opt = b.standardOptimizeOption(.{});

    const sphtud = b.dependency("sphtud", .{}).module("sphtud");

    const exe = b.addExecutable(.{
        .name = "sphone",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = opt,
        }),
    });
    exe.root_module.addImport("sphtud", sphtud);

    b.installArtifact(exe);
}
