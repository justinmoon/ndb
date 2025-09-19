const std = @import("std");
const apple_sdk = @import("build/apple_sdk.zig");

fn configureAppleSdk(b: *std.Build, step: *std.Build.Step.Compile) void {
    apple_sdk.addPaths(b, step) catch |err| {
        std.debug.print("error: failed to configure Apple SDK: {s}\n", .{@errorName(err)});
        @panic("Apple SDK setup failed");
    };
}

fn isArm64(target: std.Build.ResolvedTarget) bool {
    return target.result.cpu.arch == .aarch64 or target.result.cpu.arch == .aarch64_be;
}

fn addNostrdbCLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "nostrdb_c",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });

    if (target.result.os.tag == .macos) {
        configureAppleSdk(b, lib);
    }

    if (isArm64(target)) {
        lib.addIncludePath(b.path("src/override"));
    }
    lib.addIncludePath(b.path("nostrdb/src"));
    lib.addIncludePath(b.path("nostrdb/src/bindings/c"));
    lib.addIncludePath(b.path("nostrdb/ccan"));
    lib.addIncludePath(b.path("nostrdb/deps/lmdb"));
    lib.addIncludePath(b.path("nostrdb/deps/flatcc/include"));
    lib.addIncludePath(b.path("nostrdb/deps/secp256k1/include"));
    lib.addIncludePath(b.path("nostrdb/deps/secp256k1/src"));

    lib.addCSourceFiles(.{
        .files = &.{
            "nostrdb/src/nostrdb.c",
            "nostrdb/src/invoice.c",
            "nostrdb/src/nostr_bech32.c",
            "nostrdb/src/content_parser.c",
            "nostrdb/src/bolt11/bech32.c",
            "nostrdb/src/block.c",
            "nostrdb/deps/flatcc/src/runtime/json_parser.c",
            "nostrdb/deps/flatcc/src/runtime/verifier.c",
            "nostrdb/deps/flatcc/src/runtime/builder.c",
            "nostrdb/deps/flatcc/src/runtime/emitter.c",
            "nostrdb/deps/flatcc/src/runtime/refmap.c",
            "nostrdb/deps/lmdb/mdb.c",
            "nostrdb/deps/lmdb/midl.c",
            "src/profile_shim.c",
        },
        .flags = &.{
            "-std=c11",
            "-Wno-sign-compare",
            "-Wno-misleading-indentation",
            "-Wno-unused-function",
            "-Wno-unused-parameter",
        },
    });

    lib.addCSourceFiles(.{
        .files = &.{
            "nostrdb/ccan/ccan/crypto/sha256/sha256.c",
        },
        .flags = &.{
            "-Wno-unused-function",
            "-Wno-unused-parameter",
        },
    });

    if (target.result.os.tag != .windows) {
        lib.addCSourceFiles(.{
            .files = &.{
                "nostrdb/ccan/ccan/likely/likely.c",
                "nostrdb/ccan/ccan/list/list.c",
                "nostrdb/ccan/ccan/mem/mem.c",
                "nostrdb/ccan/ccan/str/debug.c",
                "nostrdb/ccan/ccan/str/str.c",
                "nostrdb/ccan/ccan/take/take.c",
                "nostrdb/ccan/ccan/tal/str/str.c",
                "nostrdb/ccan/ccan/tal/tal.c",
                "nostrdb/ccan/ccan/utf8/utf8.c",
                "nostrdb/src/bolt11/bolt11.c",
                "nostrdb/src/bolt11/amount.c",
                "nostrdb/src/bolt11/hash_u5.c",
            },
            .flags = &.{
                "-Wno-sign-compare",
                "-Wno-misleading-indentation",
                "-Wno-unused-function",
                "-Wno-unused-parameter",
            },
        });
    }

    lib.addCSourceFiles(.{
        .files = &.{
            "nostrdb/deps/secp256k1/contrib/lax_der_parsing.c",
            "nostrdb/deps/secp256k1/src/precomputed_ecmult_gen.c",
            "nostrdb/deps/secp256k1/src/precomputed_ecmult.c",
            "nostrdb/deps/secp256k1/src/secp256k1.c",
        },
        .flags = &.{
            "-Wno-unused-function",
            "-Wno-unused-parameter",
        },
    });

    lib.root_module.addCMacro("SECP256K1_STATIC", "1");
    lib.root_module.addCMacro("ENABLE_MODULE_ECDH", "1");
    lib.root_module.addCMacro("ENABLE_MODULE_SCHNORRSIG", "1");
    lib.root_module.addCMacro("ENABLE_MODULE_EXTRAKEYS", "1");

    lib.linkLibC();
    if (target.result.os.tag != .windows) {
        lib.linkSystemLibrary("pthread");
    }
    if (target.result.os.tag == .macos) {
        lib.linkFramework("Security");
    }

    return lib;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const c_lib = addNostrdbCLibrary(b, target, optimize);

    const c_module = b.createModule(.{
        .root_source_file = b.path("src/c.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (isArm64(target)) {
        c_module.addIncludePath(b.path("src/override"));
    }
    c_module.addIncludePath(b.path("nostrdb/src"));
    c_module.addIncludePath(b.path("nostrdb/src/bindings/c"));
    c_module.addIncludePath(b.path("nostrdb/ccan"));
    c_module.addIncludePath(b.path("nostrdb/deps/lmdb"));
    c_module.addIncludePath(b.path("nostrdb/deps/flatcc/include"));
    c_module.addIncludePath(b.path("nostrdb/deps/secp256k1/include"));
    c_module.addIncludePath(b.path("nostrdb/deps/secp256k1/src"));

    const lib_module = b.addModule("nostrdb", .{
        .root_source_file = b.path("src/ndb.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_module.addImport("c", c_module);

    const wrapper = b.addLibrary(.{
        .name = "nostrdb-zig",
        .linkage = .static,
        .root_module = lib_module,
    });
    wrapper.linkLibrary(c_lib);
    if (target.result.os.tag == .macos) {
        configureAppleSdk(b, wrapper);
        wrapper.linkFramework("Security");
    }
    b.installArtifact(wrapper);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("nostrdb", lib_module);
    tests.root_module.addImport("c", c_module);
    tests.linkLibrary(c_lib);
    if (target.result.os.tag == .macos) {
        configureAppleSdk(b, tests);
        tests.linkFramework("Security");
    }

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run wrapper tests");
    test_step.dependOn(&run_tests.step);
}
