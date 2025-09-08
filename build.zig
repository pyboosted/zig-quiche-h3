const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Options
    const use_system_quiche = b.option(bool, "system-quiche", "Use system-installed quiche via linker (pkg-config recommended)") orelse false;
    const build_quiche = b.option(bool, "build-quiche", "Build Cloudflare quiche (Cargo) before linking") orelse !use_system_quiche;
    const quiche_profile = b.option([]const u8, "quiche-profile", "Cargo profile for quiche: release|debug") orelse "release";
    const link_ssl = b.option(bool, "link-ssl", "Link libssl and libcrypto (for OpenSSL/quictls builds)") orelse false;
    const with_libev = b.option(bool, "with-libev", "Link libev system library") orelse false;
    const quiche_include_dir = b.option([]const u8, "quiche-include", "Path to quiche headers (quiche/include)") orelse "third_party/quiche/quiche/include";

    // Paths
    const quiche_root = b.path("third_party/quiche");
    const quiche_target_dir = b.path("third_party/quiche/target");
    const quiche_lib_path = b.path(b.fmt("third_party/quiche/target/{s}/libquiche.a", .{quiche_profile}));

    // Optional build step to run Cargo for quiche staticlib
    var cargo_step: ?*std.Build.Step.Run = null;
    if (build_quiche and !use_system_quiche) {
        const cargo = b.addSystemCommand(&.{ "cargo", "build", "-p", "quiche", "--features", "ffi" });
        if (std.mem.eql(u8, quiche_profile, "release")) {
            cargo.addArg("--release");
        }
        cargo.setCwd(quiche_root);
        // Ensure Cargo writes into our expected target dir
        cargo.addArgs(&.{ "--target-dir", quiche_target_dir.getPath(b) });
        cargo_step = cargo;
        // Expose a manual step: `zig build quiche`
        const quiche_build_step = b.step("quiche", "Build quiche (Cargo staticlib)");
        quiche_build_step.dependOn(&cargo.step);
    }

    // Executable: simple binary that prints quiche version (for smoke tests)
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{ .name = "zig-quiche-h3", .root_module = exe_mod });

    // Include path for quiche C FFI header
    exe_mod.addIncludePath(b.path(quiche_include_dir));

    if (use_system_quiche) {
        exe.linkSystemLibrary("quiche");
    } else {
        // Link the quiche static library built via Cargo with `--features ffi`.
        exe.addObjectFile(quiche_lib_path);
        // Verify the library exists (fast failure if missing)
        const verify_quiche = b.addSystemCommand(&.{ "test", "-f", quiche_lib_path.getPath(b) });
        exe.step.dependOn(&verify_quiche.step);
    }

    if (with_libev) exe.linkSystemLibrary("ev");
    exe.linkLibC();

    // Platform-specific C++ runtime and common deps for linking vendored BoringSSL objects.
    switch (target.result.os.tag) {
        .linux => {
            exe.linkSystemLibrary("stdc++");
            exe.linkSystemLibrary("pthread");
            exe.linkSystemLibrary("dl");
        },
        .freebsd, .openbsd, .netbsd, .dragonfly, .macos, .ios => {
            exe.linkSystemLibrary("c++");
            // macOS frameworks sometimes needed by ring/BoringSSL
            exe.linkFramework("Security");
            exe.linkFramework("CoreFoundation");
        },
        else => {},
    }
    if (link_ssl) {
        exe.linkSystemLibrary("ssl");
        exe.linkSystemLibrary("crypto");
    }

    b.installArtifact(exe);

    // `zig build run` convenience
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the demo executable");
    run_step.dependOn(&run_cmd.step);

    // Unit tests: run a test that prints quiche version
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    unit_tests.root_module.addIncludePath(b.path(quiche_include_dir));
    if (use_system_quiche) {
        unit_tests.linkSystemLibrary("quiche");
    } else {
        unit_tests.addObjectFile(quiche_lib_path);
        const verify_quiche_test = b.addSystemCommand(&.{ "test", "-f", quiche_lib_path.getPath(b) });
        unit_tests.step.dependOn(&verify_quiche_test.step);
    }
    if (with_libev) unit_tests.linkSystemLibrary("ev");
    unit_tests.linkLibC();
    switch (target.result.os.tag) {
        .linux => {
            unit_tests.linkSystemLibrary("stdc++");
            unit_tests.linkSystemLibrary("pthread");
            unit_tests.linkSystemLibrary("dl");
        },
        .freebsd, .openbsd, .netbsd, .dragonfly, .macos, .ios => {
            unit_tests.linkSystemLibrary("c++");
            unit_tests.linkFramework("Security");
            unit_tests.linkFramework("CoreFoundation");
        },
        else => {},
    }
    if (link_ssl) {
        unit_tests.linkSystemLibrary("ssl");
        unit_tests.linkSystemLibrary("crypto");
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Ensure we build quiche before compiling/linking, if requested.
    if (cargo_step) |c| {
        exe.step.dependOn(&c.step);
        unit_tests.step.dependOn(&c.step);
    }
}
