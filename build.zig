const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const opt = b.standardOptimizeOption(.{});

    const sphtud = b.dependency("sphtud", .{
        .with_gl = false,
        .with_glfw = false,
        .unique = "sphone",
    }).module("sphtud");

    const sphaudio = b.dependency("sphaudio", .{})
        .module("sphaudio");

    const exe = b.addExecutable(.{
        .name = "sphone",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = opt,
        }),
    });
    exe.root_module.addImport("sphtud", sphtud);
    exe.root_module.addImport("sphaudio", sphaudio);

    b.installArtifact(exe);

    const tests = b.addTest(.{
        .name = "tests",
        .root_module = exe.root_module,
    });
    b.installArtifact(tests);
}
