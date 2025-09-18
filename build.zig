const std = @import("std");

fn linkCommon(
    target: std.Build.ResolvedTarget,
    comp: *std.Build.Step.Compile,
    link_ssl: bool,
    with_libev: bool,
    libev_lib_dir: ?[]const u8,
    needs_cpp: bool,
) void {
    if (with_libev) {
        comp.linkSystemLibrary("ev");
        if (libev_lib_dir) |libdir| comp.addLibraryPath(.{ .cwd_relative = libdir });
    }
    comp.linkLibC();
    switch (target.result.os.tag) {
        .linux => {
            if (needs_cpp) comp.linkSystemLibrary("stdc++");
            comp.linkSystemLibrary("pthread");
            comp.linkSystemLibrary("dl");
        },
        .freebsd, .openbsd, .netbsd, .dragonfly, .macos, .ios => {
            if (needs_cpp) comp.linkSystemLibrary("c++");
            // macOS frameworks sometimes needed by ring/BoringSSL
            comp.linkFramework("Security");
            comp.linkFramework("CoreFoundation");
        },
        else => {},
    }
    if (link_ssl) {
        comp.linkSystemLibrary("ssl");
        comp.linkSystemLibrary("crypto");
    }
}

fn addQuicheLink(
    b: *std.Build,
    comp: *std.Build.Step.Compile,
    use_system_quiche: bool,
    quiche_lib_path: std.Build.LazyPath,
    cargo_step: ?*std.Build.Step.Run,
) void {
    if (use_system_quiche) {
        comp.linkSystemLibrary("quiche");
    } else {
        comp.addObjectFile(quiche_lib_path);
        const verify = b.addSystemCommand(&.{ "test", "-f", quiche_lib_path.getPath(b) });
        comp.step.dependOn(&verify.step);
    }
    if (cargo_step) |c| comp.step.dependOn(&c.step);
}

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
    const with_webtransport = b.option(bool, "with-webtransport", "Enable WebTransport (experimental)") orelse true;
    const log_level_opt = b.option([]const u8, "log-level", "Default app log level: error|warn|info|debug|trace") orelse "warn";

    // Build options accessible to modules via @import("build_options")
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "with_webtransport", with_webtransport);
    build_opts.addOption([]const u8, "log_level", log_level_opt);
    // no router-related build options

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
    // No build options needed at this level
    const exe = b.addExecutable(.{ .name = "zig-quiche-h3", .root_module = exe_mod });

    // Include path for quiche C FFI header
    exe_mod.addIncludePath(b.path(quiche_include_dir));

    addQuicheLink(b, exe, use_system_quiche, quiche_lib_path, cargo_step);
    linkCommon(target, exe, link_ssl, with_libev, libev_lib_dir, true);

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

    // Utility module needs to be created before modules that use it
    const utils_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Argument parsing module for CLI tools
    const args_mod = b.createModule(.{
        .root_source_file = b.path("src/args.zig"),
        .target = target,
        .optimize = optimize,
    });

    const connection_mod = b.createModule(.{
        .root_source_file = b.path("src/quic/connection.zig"),
        .target = target,
        .optimize = optimize,
    });
    connection_mod.addImport("quiche", quiche_ffi_mod);
    connection_mod.addImport("utils", utils_mod);
    connection_mod.addImport("event_loop", event_loop_mod);

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
    // h3 module does not directly import build_options

    // Centralized error unions module
    const errors_mod = b.createModule(.{
        .root_source_file = b.path("src/errors.zig"),
        .target = target,
        .optimize = optimize,
    });

    // HTTP module for routing and request/response handling (library default)
    const http_mod = b.createModule(.{
        .root_source_file = b.path("src/http/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    http_mod.addImport("quiche", quiche_ffi_mod);
    http_mod.addImport("h3", h3_mod);
    http_mod.addImport("errors", errors_mod);
    http_mod.addImport("config", config_mod);

    // Add errors module to h3_mod
    h3_mod.addImport("errors", errors_mod);

    // Routing ABI (phase 0) used by server
    const routing_mod = b.createModule(.{
        .root_source_file = b.path("src/routing/api.zig"),
        .target = target,
        .optimize = optimize,
    });
    routing_mod.addImport("http", http_mod);
    const routing_gen_mod = b.createModule(.{
        .root_source_file = b.path("src/routing/generator.zig"),
        .target = target,
        .optimize = optimize,
    });
    routing_gen_mod.addImport("http", http_mod);
    routing_gen_mod.addImport("routing", routing_mod);

    // Dynamic matcher (runtime builder)
    const routing_dyn_mod = b.createModule(.{
        .root_source_file = b.path("src/routing/dynamic.zig"),
        .target = target,
        .optimize = optimize,
    });
    routing_dyn_mod.addImport("http", http_mod);
    routing_dyn_mod.addImport("routing", routing_mod);

    // http module no longer needs router/static_routes

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
    server_mod.addImport("errors", errors_mod);
    server_mod.addImport("routing", routing_mod);
    server_mod.addImport("utils", utils_mod);
    server_mod.addOptions("build_options", build_opts);

    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/quic/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_mod.addImport("quiche", quiche_ffi_mod);
    client_mod.addImport("config", config_mod);
    client_mod.addImport("event_loop", event_loop_mod);
    client_mod.addImport("udp", udp_mod);
    client_mod.addImport("connection", connection_mod);
    client_mod.addImport("h3", h3_mod);
    client_mod.addImport("http", http_mod);
    // Note: server removed to avoid circular dependency
    // Tests that need server should import it directly via test_mod
    client_mod.addImport("routing", routing_mod);
    client_mod.addImport("routing_gen", routing_gen_mod);

    const h3_client_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/h3_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    h3_client_mod.addImport("client", client_mod);
    h3_client_mod.addImport("args", args_mod);

    // Consolidated hybrid router
    // no hybrid router in server

    // App-specific HTTP module that injects example static routes for the example server
    const http_mod_app = b.createModule(.{
        .root_source_file = b.path("src/http/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    http_mod_app.addImport("quiche", quiche_ffi_mod);
    http_mod_app.addImport("h3", h3_mod);
    http_mod_app.addImport("errors", errors_mod);
    http_mod_app.addImport("config", config_mod);
    // Shared handlers for example servers
    const quic_handlers_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/quic_server_handlers.zig"),
        .target = target,
        .optimize = optimize,
    });
    quic_handlers_mod.addImport("http", http_mod_app);

    // Server module for example, bound to http_mod_app
    const server_mod_app = b.createModule(.{
        .root_source_file = b.path("src/quic/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_mod_app.addImport("quiche", quiche_ffi_mod);
    server_mod_app.addImport("connection", connection_mod);
    server_mod_app.addImport("config", config_mod);
    server_mod_app.addImport("event_loop", event_loop_mod);
    server_mod_app.addImport("udp", udp_mod);
    server_mod_app.addImport("h3", h3_mod);
    server_mod_app.addImport("http", http_mod_app);
    server_mod_app.addImport("errors", errors_mod);
    server_mod_app.addImport("utils", utils_mod);
    const routing_mod_app = b.createModule(.{
        .root_source_file = b.path("src/routing/api.zig"),
        .target = target,
        .optimize = optimize,
    });
    routing_mod_app.addImport("http", http_mod_app);
    server_mod_app.addImport("routing", routing_mod_app);
    const routing_gen_mod_app = b.createModule(.{
        .root_source_file = b.path("src/routing/generator.zig"),
        .target = target,
        .optimize = optimize,
    });
    routing_gen_mod_app.addImport("http", http_mod_app);
    routing_gen_mod_app.addImport("routing", routing_mod_app);
    server_mod_app.addOptions("build_options", build_opts);

    // Dynamic matcher module bound to app's http module
    const routing_dyn_mod_app = b.createModule(.{
        .root_source_file = b.path("src/routing/dynamic.zig"),
        .target = target,
        .optimize = optimize,
    });
    routing_dyn_mod_app.addImport("http", http_mod_app);
    routing_dyn_mod_app.addImport("routing", routing_mod_app);

    // No router module

    // Remove legacy quic-server (router-based)

    // QUIC server using matcher generator (canonical example)
    if (with_libev) {
        const quic_server_mod = b.createModule(.{
            .root_source_file = b.path("src/examples/quic_server.zig"),
            .target = target,
            .optimize = optimize,
        });
        quic_server_mod.addImport("server", server_mod_app);
        quic_server_mod.addImport("config", config_mod);
        quic_server_mod.addImport("http", http_mod_app);
        quic_server_mod.addImport("connection", connection_mod);
        quic_server_mod.addImport("handlers", quic_handlers_mod);
        quic_server_mod.addImport("routing", routing_mod_app);
        quic_server_mod.addImport("routing_gen", routing_gen_mod_app);
        quic_server_mod.addImport("args", args_mod);

        const quic_server = b.addExecutable(.{ .name = "quic-server", .root_module = quic_server_mod });
        addQuicheLink(b, quic_server, use_system_quiche, quiche_lib_path, cargo_step);
        linkCommon(target, quic_server, link_ssl, with_libev, libev_lib_dir, true);
        b.installArtifact(quic_server);
        const run_qs = b.addRunArtifact(quic_server);
        if (b.args) |args| run_qs.addArgs(args);
        const qs_step = b.step("quic-server", "Run the QUIC server example");
        qs_step.dependOn(&run_qs.step);
    }

    // QUIC dynamic matcher example
    if (with_libev) {
        const quic_server_dyn_mod = b.createModule(.{
            .root_source_file = b.path("src/examples/quic_server_dyn.zig"),
            .target = target,
            .optimize = optimize,
        });
        quic_server_dyn_mod.addImport("server", server_mod_app);
        quic_server_dyn_mod.addImport("config", config_mod);
        quic_server_dyn_mod.addImport("http", http_mod_app);
        quic_server_dyn_mod.addImport("connection", connection_mod);
        quic_server_dyn_mod.addImport("routing", routing_mod_app);
        quic_server_dyn_mod.addImport("routing_dyn", routing_dyn_mod_app);
        quic_server_dyn_mod.addImport("handlers", quic_handlers_mod);
        quic_server_dyn_mod.addImport("args", args_mod);

        const quic_server_dyn = b.addExecutable(.{ .name = "quic-server-dyn", .root_module = quic_server_dyn_mod });
        addQuicheLink(b, quic_server_dyn, use_system_quiche, quiche_lib_path, cargo_step);
        linkCommon(target, quic_server_dyn, link_ssl, with_libev, libev_lib_dir, true);
        b.installArtifact(quic_server_dyn);
        const run_qs_dyn = b.addRunArtifact(quic_server_dyn);
        if (b.args) |args| run_qs_dyn.addArgs(args);
        const qs_dyn_step = b.step("quic-server-dyn", "Run the QUIC server with dynamic matcher");
        qs_dyn_step.dependOn(&run_qs_dyn.step);
    }

    // QUIC DATAGRAM echo example (requires libev) - matcher v2
    if (with_libev) {
        const dgram_echo_mod = b.createModule(.{
            .root_source_file = b.path("src/examples/quic_dgram_echo.zig"),
            .target = target,
            .optimize = optimize,
        });
        dgram_echo_mod.addImport("server", server_mod_app);
        dgram_echo_mod.addImport("config", config_mod);
        dgram_echo_mod.addImport("http", http_mod_app);
        dgram_echo_mod.addImport("connection", connection_mod);
        dgram_echo_mod.addImport("h3", h3_mod);
        dgram_echo_mod.addImport("routing", routing_mod_app);
        dgram_echo_mod.addImport("routing_gen", routing_gen_mod_app);
        dgram_echo_mod.addImport("args", args_mod);

        const dgram_echo = b.addExecutable(.{ .name = "quic-dgram-echo", .root_module = dgram_echo_mod });
        addQuicheLink(b, dgram_echo, use_system_quiche, quiche_lib_path, cargo_step);
        linkCommon(target, dgram_echo, link_ssl, with_libev, libev_lib_dir, true);
        b.installArtifact(dgram_echo);
        const run_dgram = b.addRunArtifact(dgram_echo);
        if (b.args) |args| run_dgram.addArgs(args);
        const dgram_step = b.step("quic-dgram-echo", "Run QUIC DATAGRAM echo example (requires libev)");
        dgram_step.dependOn(&run_dgram.step);
    }

    if (with_libev) {
        const h3_client = b.addExecutable(.{ .name = "h3-client", .root_module = h3_client_mod });
        addQuicheLink(b, h3_client, use_system_quiche, quiche_lib_path, cargo_step);
        linkCommon(target, h3_client, link_ssl, with_libev, libev_lib_dir, true);
        b.installArtifact(h3_client);
        const run_h3_client = b.addRunArtifact(h3_client);
        if (b.args) |cli_args| run_h3_client.addArgs(cli_args);
        const h3_client_step = b.step("h3-client", "Run the HTTP/3 client CLI");
        h3_client_step.dependOn(&run_h3_client.step);
    }

    // WebTransport test client (only when explicitly enabled)
    if (with_webtransport) {
        const wt_client_mod = b.createModule(.{
            .root_source_file = b.path("src/examples/wt_client.zig"),
            .target = target,
            .optimize = optimize,
        });
        wt_client_mod.addImport("quiche", quiche_ffi_mod);
        wt_client_mod.addImport("h3", h3_mod);
        wt_client_mod.addImport("net", udp_mod);
        wt_client_mod.addImport("args", args_mod);
        // wt client does not import build_options

        const wt_client = b.addExecutable(.{
            .name = "wt-client",
            .root_module = wt_client_mod,
        });

        addQuicheLink(b, wt_client, use_system_quiche, quiche_lib_path, cargo_step);
        linkCommon(target, wt_client, link_ssl, with_libev, libev_lib_dir, true);

        b.installArtifact(wt_client);

        const run_wt_client = b.addRunArtifact(wt_client);
        if (b.args) |args| run_wt_client.addArgs(args);
        const wt_client_step = b.step("wt-client", "Run the WebTransport test client (Experimental)");
        wt_client_step.dependOn(&run_wt_client.step);
    }

    // Unit tests: run a test that prints quiche version
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Provide module imports used by tests
    test_mod.addImport("http", http_mod);
    test_mod.addImport("routing", routing_mod);
    test_mod.addImport("routing_gen", routing_gen_mod);
    test_mod.addImport("routing_dyn", routing_dyn_mod);
    test_mod.addImport("client", client_mod);
    test_mod.addImport("server", server_mod); // For client tests that need a server
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    unit_tests.root_module.addIncludePath(b.path(quiche_include_dir));
    addQuicheLink(b, unit_tests, use_system_quiche, quiche_lib_path, cargo_step);
    linkCommon(target, unit_tests, link_ssl, with_libev, libev_lib_dir, true);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Benchmark for compile-time optimizations
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmarks/comptime_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("http", http_mod);
    const bench = b.addExecutable(.{
        .name = "comptime-bench",
        .root_module = bench_mod,
    });
    bench.root_module.addIncludePath(b.path(quiche_include_dir));
    addQuicheLink(b, bench, use_system_quiche, quiche_lib_path, cargo_step);
    linkCommon(target, bench, link_ssl, with_libev, libev_lib_dir, false);

    b.installArtifact(bench);
    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run compile-time optimization benchmarks");
    bench_step.dependOn(&run_bench.step);

    // Shared library for Bun FFI smoke tests: exports zig_h3_version()
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addIncludePath(b.path(quiche_include_dir));
    const lib = b.addLibrary(.{ .name = "zigquicheh3", .root_module = lib_mod, .linkage = .dynamic });
    addQuicheLink(b, lib, use_system_quiche, quiche_lib_path, cargo_step);
    linkCommon(target, lib, link_ssl, with_libev, libev_lib_dir, true);
    b.installArtifact(lib);

    // Ensure we build quiche before compiling/linking is handled in addQuicheLink()

    // Milestone 1 demo: UDP echo server using libev event loop

    // Create echo module and add imports
    const echo_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/udp_echo.zig"),
        .target = target,
        .optimize = optimize,
    });
    echo_mod.addImport("event_loop", event_loop_mod);
    echo_mod.addImport("udp", udp_mod);

    if (with_libev) {
        const echo = b.addExecutable(.{ .name = "udp-echo", .root_module = echo_mod });
        linkCommon(target, echo, false, with_libev, libev_lib_dir, false);
        b.installArtifact(echo);
        const run_echo = b.addRunArtifact(echo);
        if (b.args) |args| run_echo.addArgs(args);
        const echo_step = b.step("echo", "Run UDP echo example (requires libev)");
        echo_step.dependOn(&run_echo.step);
    }
}
