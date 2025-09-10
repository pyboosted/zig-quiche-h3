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
    const libev_include_dir = b.option([]const u8, "libev-include", "Path to libev headers (dir containing ev.h)");
    const libev_lib_dir = b.option([]const u8, "libev-lib", "Path to libev library directory (contains libev.dylib/.so)");
    const quiche_include_dir = b.option([]const u8, "quiche-include", "Path to quiche headers (quiche/include)") orelse "third_party/quiche/quiche/include";

    // Paths
    const quiche_root = b.path("third_party/quiche");
    const quiche_target_dir = b.path("third_party/quiche/target");
    const quiche_lib_path = b.path(b.fmt("third_party/quiche/target/{s}/libquiche.a", .{quiche_profile}));

    // Optional build step to run Cargo for quiche staticlib
    var cargo_step: ?*std.Build.Step.Run = null;
    if (build_quiche and !use_system_quiche) {
        const cargo = b.addSystemCommand(&.{ "cargo", "build", "-p", "quiche", "--features", "ffi,qlog" });
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

    if (with_libev) {
        exe.linkSystemLibrary("ev");
        if (libev_lib_dir) |libdir| exe.addLibraryPath(.{ .cwd_relative = libdir });
    }
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
    
    // Create shared modules first (used by both M1 and M2)
    // Event loop module with proper include paths
    const event_loop_mod = b.createModule(.{
        .root_source_file = b.path("src/net/event_loop.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Add libev include path to the module that needs it for @cImport
    if (libev_include_dir) |inc| {
        event_loop_mod.addIncludePath(.{ .cwd_relative = inc });
    }
    
    // UDP module
    const udp_mod = b.createModule(.{
        .root_source_file = b.path("src/net/udp.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Milestone 2: QUIC Server
    // Create modules for QUIC components
    const quiche_ffi_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi/quiche.zig"),
        .target = target,
        .optimize = optimize,
    });
    quiche_ffi_mod.addIncludePath(b.path(quiche_include_dir));
    
    const connection_mod = b.createModule(.{
        .root_source_file = b.path("src/quic/connection.zig"),
        .target = target,
        .optimize = optimize,
    });
    connection_mod.addImport("quiche", quiche_ffi_mod);
    
    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/quic/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // H3 module for HTTP/3 support
    const h3_mod = b.createModule(.{
        .root_source_file = b.path("src/h3/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    h3_mod.addImport("quiche", quiche_ffi_mod);
    
    // HTTP module for routing and request/response handling
    const http_mod = b.createModule(.{
        .root_source_file = b.path("src/http/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    http_mod.addImport("quiche", quiche_ffi_mod);
    http_mod.addImport("h3", h3_mod);
    
    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/quic/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_mod.addImport("quiche", quiche_ffi_mod);
    server_mod.addImport("connection", connection_mod);
    server_mod.addImport("config", config_mod);
    server_mod.addImport("event_loop", event_loop_mod);
    server_mod.addImport("udp", udp_mod);
    server_mod.addImport("h3", h3_mod);
    server_mod.addImport("http", http_mod);
    
    // QUIC server executable
    const quic_server_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/quic_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    quic_server_mod.addImport("server", server_mod);
    quic_server_mod.addImport("config", config_mod);
    quic_server_mod.addImport("http", http_mod);
    quic_server_mod.addImport("connection", connection_mod);
    
    const quic_server = b.addExecutable(.{
        .name = "quic-server",
        .root_module = quic_server_mod,
    });
    
    // Link quiche and dependencies
    if (use_system_quiche) {
        quic_server.linkSystemLibrary("quiche");
    } else {
        quic_server.addObjectFile(quiche_lib_path);
        const verify_quiche_server = b.addSystemCommand(&.{ "test", "-f", quiche_lib_path.getPath(b) });
        quic_server.step.dependOn(&verify_quiche_server.step);
    }
    
    // Link libev
    if (with_libev) {
        quic_server.linkSystemLibrary("ev");
        if (libev_lib_dir) |libdir| quic_server.addLibraryPath(.{ .cwd_relative = libdir });
    }
    
    quic_server.linkLibC();
    
    // Platform-specific dependencies
    switch (target.result.os.tag) {
        .linux => {
            quic_server.linkSystemLibrary("stdc++");
            quic_server.linkSystemLibrary("pthread");
            quic_server.linkSystemLibrary("dl");
        },
        .freebsd, .openbsd, .netbsd, .dragonfly, .macos, .ios => {
            quic_server.linkSystemLibrary("c++");
            quic_server.linkFramework("Security");
            quic_server.linkFramework("CoreFoundation");
        },
        else => {},
    }
    
    if (link_ssl) {
        quic_server.linkSystemLibrary("ssl");
        quic_server.linkSystemLibrary("crypto");
    }
    
    // Ensure quiche is built first if needed
    if (cargo_step) |c| {
        quic_server.step.dependOn(&c.step);
    }
    
    b.installArtifact(quic_server);
    
    // Run command for QUIC server
    const run_quic_server = b.addRunArtifact(quic_server);
    if (b.args) |args| run_quic_server.addArgs(args);
    const quic_server_step = b.step("quic-server", "Run the QUIC server (Milestone 2)");
    quic_server_step.dependOn(&run_quic_server.step);

    // QUIC DATAGRAM echo example
    const dgram_echo_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/quic_dgram_echo.zig"),
        .target = target,
        .optimize = optimize,
    });
    dgram_echo_mod.addImport("server", server_mod);
    dgram_echo_mod.addImport("config", config_mod);
    dgram_echo_mod.addImport("http", http_mod);
    dgram_echo_mod.addImport("connection", connection_mod);

    const dgram_echo = b.addExecutable(.{ .name = "quic-dgram-echo", .root_module = dgram_echo_mod });
    if (use_system_quiche) {
        dgram_echo.linkSystemLibrary("quiche");
    } else {
        dgram_echo.addObjectFile(quiche_lib_path);
        const verify_quiche_dgram = b.addSystemCommand(&.{ "test", "-f", quiche_lib_path.getPath(b) });
        dgram_echo.step.dependOn(&verify_quiche_dgram.step);
    }
    if (with_libev) {
        dgram_echo.linkSystemLibrary("ev");
        if (libev_lib_dir) |libdir| dgram_echo.addLibraryPath(.{ .cwd_relative = libdir });
    }
    dgram_echo.linkLibC();
    switch (target.result.os.tag) {
        .linux => {
            dgram_echo.linkSystemLibrary("stdc++");
            dgram_echo.linkSystemLibrary("pthread");
            dgram_echo.linkSystemLibrary("dl");
        },
        .freebsd, .openbsd, .netbsd, .dragonfly, .macos, .ios => {
            dgram_echo.linkSystemLibrary("c++");
            dgram_echo.linkFramework("Security");
            dgram_echo.linkFramework("CoreFoundation");
        },
        else => {},
    }
    if (link_ssl) {
        dgram_echo.linkSystemLibrary("ssl");
        dgram_echo.linkSystemLibrary("crypto");
    }
    b.installArtifact(dgram_echo);
    const run_dgram = b.addRunArtifact(dgram_echo);
    if (b.args) |args| run_dgram.addArgs(args);
    const dgram_step = b.step("quic-dgram-echo", "Run QUIC DATAGRAM echo example");
    dgram_step.dependOn(&run_dgram.step);

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
    if (with_libev) {
        unit_tests.linkSystemLibrary("ev");
        if (libev_lib_dir) |libdir| unit_tests.addLibraryPath(.{ .cwd_relative = libdir });
    }
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

    // Shared library for Bun FFI smoke tests: exports zig_h3_version()
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addIncludePath(b.path(quiche_include_dir));
    const lib = b.addLibrary(.{ .name = "zigquicheh3", .root_module = lib_mod, .linkage = .dynamic });
    if (use_system_quiche) {
        lib.linkSystemLibrary("quiche");
    } else {
        lib.addObjectFile(quiche_lib_path);
        const verify_quiche_lib = b.addSystemCommand(&.{ "test", "-f", quiche_lib_path.getPath(b) });
        lib.step.dependOn(&verify_quiche_lib.step);
    }
    if (with_libev) {
        lib.linkSystemLibrary("ev");
        if (libev_lib_dir) |libdir| lib.addLibraryPath(.{ .cwd_relative = libdir });
    }
    lib.linkLibC();
    switch (target.result.os.tag) {
        .linux => {
            lib.linkSystemLibrary("stdc++");
            lib.linkSystemLibrary("pthread");
            lib.linkSystemLibrary("dl");
        },
        .freebsd, .openbsd, .netbsd, .dragonfly, .macos, .ios => {
            lib.linkSystemLibrary("c++");
            lib.linkFramework("Security");
            lib.linkFramework("CoreFoundation");
        },
        else => {},
    }
    if (link_ssl) {
        lib.linkSystemLibrary("ssl");
        lib.linkSystemLibrary("crypto");
    }
    b.installArtifact(lib);

    // Ensure we build quiche before compiling/linking, if requested.
    if (cargo_step) |c| {
        exe.step.dependOn(&c.step);
        unit_tests.step.dependOn(&c.step);
        lib.step.dependOn(&c.step);
    }

    // Milestone 1 demo: UDP echo server using libev event loop
    
    // Create echo module and add imports
    const echo_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/udp_echo.zig"),
        .target = target,
        .optimize = optimize,
    });
    echo_mod.addImport("event_loop", event_loop_mod);
    echo_mod.addImport("udp", udp_mod);
    
    const echo = b.addExecutable(.{ .name = "udp-echo", .root_module = echo_mod });
    // Link libev and libc
    echo.linkLibC();
    if (with_libev) {
        echo.linkSystemLibrary("ev");
        if (libev_lib_dir) |libdir| echo.addLibraryPath(.{ .cwd_relative = libdir });
    }
    // Install and run
    b.installArtifact(echo);
    const run_echo = b.addRunArtifact(echo);
    if (b.args) |args| run_echo.addArgs(args);
    const echo_step = b.step("echo", "Run UDP echo example (nc -u localhost 4433)");
    echo_step.dependOn(&run_echo.step);
}
