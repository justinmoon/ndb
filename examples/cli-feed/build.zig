const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nostrdb_dep = b.dependency("nostrdb", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("nostrdb", nostrdb_dep.module("nostrdb"));

    const exe = b.addExecutable(.{
        .name = "cli-feed",
        .root_module = exe_module,
    });
    exe.linkLibrary(nostrdb_dep.artifact("nostrdb-zig"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the cli-feed example");
    run_step.dependOn(&run_cmd.step);
}
