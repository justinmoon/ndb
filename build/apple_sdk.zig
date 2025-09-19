const std = @import("std");

/// Configure a compile step to use the native Apple SDK paths for libc,
/// frameworks, and system libraries.
pub fn addPaths(
    b: *std.Build,
    step: *std.Build.Step.Compile,
) !void {
    var target_copy = step.rootModuleTarget();
    const target = target_copy;

    const cache = struct {
        const Key = struct {
            arch: std.Target.Cpu.Arch,
            os: std.Target.Os.Tag,
            abi: std.Target.Abi,
        };

        var map: std.AutoHashMapUnmanaged(Key, ?struct {
            libc: std.Build.LazyPath,
            framework: []const u8,
            system_include: []const u8,
            library: []const u8,
        }) = .{};
    };

    const gop = try cache.map.getOrPut(b.allocator, .{
        .arch = target.cpu.arch,
        .os = target.os.tag,
        .abi = target.abi,
    });

    if (!gop.found_existing) {
        const libc = try std.zig.LibCInstallation.findNative(.{
            .allocator = b.allocator,
            .target = &target_copy,
            .verbose = false,
        });

        var list = std.array_list.Managed(u8).init(b.allocator);
        defer list.deinit();
        var deprecated_writer = list.writer();
        var adapter = deprecated_writer.adaptToNewApi(&[_]u8{});
        try libc.render(&adapter.new_interface);
        if (adapter.err) |e| return e;

        const wf = b.addWriteFiles();
        const path = wf.add("libc.txt", list.items);

        const framework_path = blk: {
            const down1 = std.fs.path.dirname(libc.sys_include_dir.?).?;
            const down2 = std.fs.path.dirname(down1).?;
            break :blk try std.fs.path.join(b.allocator, &.{
                down2,
                "System",
                "Library",
                "Frameworks",
            });
        };

        const library_path = try std.fs.path.join(b.allocator, &.{
            std.fs.path.dirname(libc.sys_include_dir.?).?,
            "lib",
        });

        gop.value_ptr.* = .{
            .libc = path,
            .framework = framework_path,
            .system_include = libc.sys_include_dir.?,
            .library = library_path,
        };
    }

    const value = gop.value_ptr.* orelse return switch (target.os.tag) {
        .macos => error.XcodeMacOSSDKNotFound,
        .ios => error.XcodeiOSSDKNotFound,
        .tvos => error.XcodeTVOSSDKNotFound,
        .watchos => error.XcodeWatchOSSDKNotFound,
        else => error.XcodeAppleSDKNotFound,
    };

    step.setLibCFile(value.libc);
    step.root_module.addSystemFrameworkPath(.{ .cwd_relative = value.framework });
    step.root_module.addSystemIncludePath(.{ .cwd_relative = value.system_include });
    step.root_module.addLibraryPath(.{ .cwd_relative = value.library });
}
