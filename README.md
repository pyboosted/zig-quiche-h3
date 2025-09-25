# zig-quiche-h3

> ⚠️ Experimental only. This codebase is a playground for QUIC + HTTP/3 in Zig; it is **not** production ready. Expect breaking changes, partial implementations, and sharp edges.

## Overview
This repository explores how far Zig can push Cloudflare’s [`quiche`](https://github.com/cloudflare/quiche) when accessed through its C FFI. It ships a libev-backed event loop, reusable HTTP/3 server scaffolding, QUIC and H3 DATAGRAM helpers, and experimental WebTransport hooks. Routing can be defined at compile time or build up at runtime, and both paths share the same matcher core so precedence and wildcard handling stay consistent.

## Repository Layout
- `build.zig` — orchestrates Zig builds, drives Cargo for vendored quiche, toggles system vs. bundled linkage.
- `src/`
  - `args.zig` — struct-based CLI parser used by all examples.
  - `net/` — libev event loop (`event_loop.zig`), UDP helpers, timers, signal wiring.
  - `quic/` — server façade, connection state, config, qlog wiring, send/recv loop.
  - `h3/` — HTTP/3 connection lifecycle, streaming/writer internals, trailer support.
  - `routing/` — compile-time generator, dynamic builder, and `matcher_core.zig` shared literal/segment tables.
  - `http/` — request/response surfaces, status tables, JSON helpers, streaming extensions.
  - `ffi/` — Zig wrappers around `quiche.h` plus the lightweight shared library exports.
  - `examples/` — `udp_echo.zig`, `quic_server.zig`, `quic_dgram_echo.zig`, `wt_client.zig` (WebTransport example client for datagram echo).
  - `tests.zig` — umbrella unit-test entry point (also prints quiche version during `zig build test`).
- `third_party/quiche/` — git submodule (upstream quiche sources).
- `docs/` — specification, implementation plan, and deeper design logs.
- `qlogs/` — runtime output when qlog capture is enabled.

## Prerequisites
- Zig 0.15.1+
- Rust toolchain 1.82+ (Cargo builds the vendored quiche unless `-Dsystem-quiche=true`)
- C toolchain (`clang`/`gcc`) and `pkg-config`
- libev headers/libraries when using the default event loop
  - macOS: `brew install libev`
  - Debian/Ubuntu: `sudo apt-get install libev-dev`
- Optional OpenSSL/quictls headers if you enable `-Dlink-ssl=true`
- Initialize submodules after cloning: `git submodule update --init --recursive`

## Building & Running
```
git submodule update --init --recursive
zig build                     # builds quiche (release profile by default) + project
zig build run                 # smoke app prints quiche version
zig build -Dsystem-quiche=true  # link against a system-provided libquiche instead
```

Useful flags:
- `-Dquiche-profile=release|debug` – select the Cargo profile for vendored quiche
- `-Dwith-libev=true -Dlibev-include=… -Dlibev-lib=…` – build examples that depend on libev
- `-Dlink-ssl=true` – point at OpenSSL/quictls instead of vendored BoringSSL
- `-Dwith-webtransport=false` – build without experimental WT support

### Examples
- UDP echo: `zig build echo -Dwith-libev=true …` then send using `nc -u localhost 4433`
- HTTP/3 server: `zig build quic-server -Dwith-libev=true … -- --port 4433 --cert … --key …`
  - Exercise with quiche client: `cargo run -p quiche_apps --bin quiche-client -- https://127.0.0.1:4433/ --no-verify --alpn h3`
  - JSON routes: `… -- https://127.0.0.1:4433/api/users --no-verify --alpn h3`
- QUIC DATAGRAM echo: `zig build quic-dgram-echo -Dwith-libev=true …`
- HTTP/3 DATAGRAM route: `GET /h3dgram/echo` echoes H3 DATAGRAM payloads when the peer negotiates the extension
- WebTransport example client (datagram echo): `zig build wt-client -Dwith-libev=true … -- --url https://127.0.0.1:4433/wt/echo`

### Qlog Capture
- Servers write per-connection traces under `qlogs/` by default (`--no_qlog` disables this). Each filename is derived from the connection ID for easy lookup in [qvis](https://qvis.edm.uhasselt.be/).
- The WebTransport example client stores its traces under `qlogs/client/`; clean the directory between runs if you want a fresh capture set.
- When iterating locally, pair `zig build quic-server …` with `zig build wt-client …` and inspect both qlogs to diagnose handshake or datagram flows.

### Tests
- Unit tests / smoke: `zig build test`
- Bun E2E (requires Bun 1.x):
  - `bun install`
  - `bun test tests/e2e`
  - Stress: `H3_STRESS=1 bun test`

## Feature Highlights
- Shared routing matcher core: both compile-time and dynamic registration feed `matcher_core.zig`, so HEAD fallbacks and 405 handling behave identically.
- Response helpers split into focused modules (`response/core.zig`, `response/body.zig`, `response/datagram.zig`, `response/streaming_ext.zig`) with a comptime status-text table.
- Per-connection counters (`active_requests`, `active_downloads`) back stopgap gating without scanning hash tables.
- Reusable per-connection DATAGRAM buffer (falls back to allocator for oversized payloads) to reduce allocation churn.
- Configurable compile-time CLI parser (`src/args.zig`) powering every example binary.
- Experimental WebTransport (WT) shim is on by default—toggle with build flags and `H3_WEBTRANSPORT=1` at runtime.

## Roadmap Snapshot
- M1: Event loop + UDP echo ✅
- M2: QUIC handshake + qlog ✅
- M3: Minimal HTTP/3 ✅
- M4: Routing + HTTP surface ✅
- M5: Streaming bodies ✅
- M6: QUIC/H3 DATAGRAM ✅
- M7: H3 DATAGRAM flow-ids ✅
- M8: WebTransport surfaces ✅ (server-side complete; full client/interop pass TBD)
- M9: Dedicated H3/WebTransport client harness (planned)
- M10: Interop + performance tuning (blocked on M9)
- M11: Bun FFI surface (planned)

## Current Status
- `quiche` FFI bindings wrap config/connection/H3 APIs with Zig-friendly types and error unions; qlog capture integrates with build flags.
- libev-backed event loop drives UDP sockets, timers, and signals; dual-stack binding helpers ship in `src/net/udp.zig`.
- QUIC server accepts handshakes, negotiates ALPN, tracks connection state, and exports metrics.
- HTTP/3 layer streams headers/bodies/trailers through a split response implementation with comptime status strings.
- Routing tables (static and dynamic) share literal/segment storage built by `matcher_core.zig`, keeping method precedence and wildcards unified.
- Request/response surfaces use arena allocators per request, optional typed JSON responses, and backpressure-aware streaming helpers.
- DATAGRAM handling supports both raw QUIC and HTTP/3 flows; per-connection buffers minimize allocations under typical MTUs.
- WebTransport: Extended CONNECT negotiation, basic session bookkeeping, and an example client for datagram echo (stream support still experimental).
- Shared library export (`zigquicheh3`) enables quick FFI smoke checks; Bun E2E harness covers core routes, datagrams, and stress runs.

See `docs/spec.md` for the detailed technical specification and `docs/plan.md` for milestone-by-milestone progress. `AGENTS.md` captures contributor expectations.
