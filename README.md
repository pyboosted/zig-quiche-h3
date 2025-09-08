# zig-quiche-h3

> Important notice: This library is experimental, under active development, and highly unlikely to ever reach a production‑ready state. It exists for internal and study purposes only. Use at your own risk and do not deploy to production.

## Overview
A Zig exploration of QUIC/HTTP‑3 built on Cloudflare’s quiche via its C FFI. The repo contains a small event loop (libev‑backed), a UDP echo demo, and a minimal QUIC server suitable for interop experiments and learning.

## Repository Layout
- `build.zig` — orchestrates Zig builds and links `quiche` (vendor or system).
- `src/`
  - `net/` — `event_loop.zig`, `udp.zig` (libev integration + UDP helpers).
  - `quic/` — `config.zig`, `connection.zig`, `server.zig` (accept, drive, qlog).
  - `h3/` — `config.zig`, `connection.zig`, `event.zig` (HTTP/3 protocol layer).
  - `http/` — `router.zig`, `request.zig`, `response.zig`, `json.zig` (HTTP abstractions).
  - `ffi/` — `quiche.zig` (C header bridge) and `../ffi.zig` (shared lib export).
  - `examples/` — `udp_echo.zig`, `quic_server.zig`.
  - `tests.zig` — tiny sanity test printing `quiche` version.
- `third_party/quiche/` — Git submodule; do not patch here.
- `docs/` — design and plan notes; `qlogs/` — runtime qlog output.

## Prerequisites
- Zig toolchain 0.15.1 or later, and a C toolchain (`clang`/`gcc`).
- Rust and Cargo (required to build vendored `quiche`): Rust 1.82+.
- libev headers and library if using the event loop:
  - macOS: `brew install libev`
  - Debian/Ubuntu: `sudo apt-get install libev-dev`
- Optional SSL libs if you pass `-Dlink-ssl=true` or use a system `quiche` linked to OpenSSL/quictls:
  - macOS: `brew install openssl@3`
  - Debian/Ubuntu: `sudo apt-get install libssl-dev`
- `pkg-config` recommended when linking system libraries.
- Git submodules initialized: `git submodule update --init --recursive`.

## Build & Run
- One‑time: `git submodule update --init --recursive`
- Build (default: builds quiche via Cargo): `zig build`
  - Use system quiche instead: `zig build -Dsystem-quiche=true`
  - Useful flags: `-Dquiche-profile=release|debug`, `-Dwith-libev=true -Dlibev-include=… -Dlibev-lib=…`, `-Dlink-ssl=true`
- Run smoke app: `zig build run` (prints `quiche` version)
- UDP echo: `zig build echo` then send with `nc -u localhost 4433`
- QUIC server: `zig build quic-server -- --port 4433 --cert third_party/quiche/quiche/examples/cert.crt --key third_party/quiche/quiche/examples/cert.key`
  - Test with quiche client: `cd third_party/quiche && cargo run -p quiche --bin quiche-client -- https://127.0.0.1:4433/ --no-verify`
  - Test JSON endpoints: `cargo run -p quiche_apps --bin quiche-client -- https://127.0.0.1:4433/api/users --no-verify`
- Tests: `zig build test`

## Roadmap
- M1: Event loop + UDP echo (done)
- M2: QUIC server with handshake, timers, qlog, dual‑stack UDP (done)
- M3: Minimal HTTP/3 request/response path (H3 frames + streams) (done)
- M4: Dynamic routing with type-safe JSON serialization (done)
- M5: Streaming bodies with backpressure handling
- M6: DATAGRAM support (QUIC + H3), feature flags
- M7: H3 DATAGRAM with flow‑id mapping
- M8: WebTransport (experimental)
- M9: Interop + Performance
- M10: Bun FFI integration

## What's Done So Far
- Wired `quiche` C FFI and basic Zig wrappers; enabled debug logging and qlog output.
- Implemented IPv4/IPv6 UDP binding, libev‑based IO/timers/signals.
- Accepts QUIC Initial, negotiates ALPN (prioritizes `h3` for HTTP/3), drives handshake, and drains egress.
- Connection table, HMAC‑derived SCIDs, timeout processing, and send/recv paths.
- HTTP/3 support: H3 connection management, event polling, header processing, dynamic response generation.
- Dynamic routing: Pattern matching (`/api/users/:id`), wildcard paths (`/files/*`), parameter extraction.
- Type-safe JSON: Uses `std.json.Stringify.valueAlloc()` for structured data serialization.
- Request/Response API: Arena‑allocated per request, chainable response methods, zero‑cost cleanup.
- Memory optimizations: Eliminated header duplication, single JSON allocation via arena.
- Shared library export (`zigquicheh3`) for simple FFI smoke tests; unit test prints `quiche` version.

See `AGENTS.md` for contributor guidelines and `docs/` for detailed design notes.
