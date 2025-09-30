# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Structure & Module Organization
- `build.zig` — Zig build script; installs to `zig-out/bin/`.
- `src/` — main code:
  - `net/` (event loop, UDP), `quic/` (config, connection, server, client), `routing/` (generator, dynamic builder, matcher core), `http/` (request/response surfaces), `ffi/` (quiche C FFI + Bun FFI exports).
  - `examples/`: `udp_echo.zig`, `quic_server.zig`, `quic_dgram_echo.zig`, `wt_client.zig`, `h3_client.zig` (native HTTP/3 client), `pool_client.zig`.
  - `main.zig` (smoke binary), `tests.zig` (unit tests).
- `third_party/quiche/` — Cloudflare quiche submodule (do not edit).
- `docs/` — design notes, milestones (`plan.md`, `bun-ffi-plan.md`, `client-plan.md`); `qlogs/` — QUIC qlog output.
- `tests/e2e/` — Bun-based end-to-end test harness using native h3-client binary and FFI.

## Build, Test, and Development Commands
- Init deps: `git submodule update --init --recursive`.
- Build quiche (default when not using system lib): `zig build quiche` or simply `zig build` (runs Cargo for quiche).
- Use system quiche: `zig build -Dsystem-quiche=true`.
- Common flags: `-Dquiche-profile=release|debug`, `-Dwith-libev=true -Dlibev-include=… -Dlibev-lib=…`, `-Dlink-ssl=true`, `-Dwith-webtransport=false|true` (default true).
- Build binary: `zig build` → `zig-out/bin/zig-quiche-h3`.
- Build Bun FFI shared library: `zig build bun-ffi` → `zig-out/lib/libzigquicheh3.{dylib,so}` + `zig-out/include/zig_h3.h`.
- Smoke app: `zig build run` (prints quiche version).
- Examples (libev required for server binaries):
  - UDP echo: `zig build echo` → send with `nc -u localhost 4433`.
  - QUIC server (compile-time routes): `zig build quic-server -- --port 4433 --cert third_party/quiche/quiche/examples/cert.crt --key third_party/quiche/quiche/examples/cert.key`.
  - QUIC server (runtime routes): `zig build quic-server-dyn -- --port 4433 --cert … --key …`.
  - QUIC dgram echo: `zig build quic-dgram-echo -- --port 4433 --cert … --key …`.
  - WebTransport stub client: `zig build wt-client -- https://127.0.0.1:4433/wt/echo`.
  - Native HTTP/3 client: `zig build h3-client` → `./zig-out/bin/h3-client --url https://127.0.0.1:4433/ --insecure`.
  - Connection pool demo: `zig build pool-client`.
- Tests:
  - Unit: `zig build test` or `zig test src/tests.zig`.
  - E2E (Bun): `bun install && bun test tests/e2e`.
  - Stress: `H3_STRESS=1 bun test`.
  - Verbose: `H3_VERBOSE=1 bun test`.
  - Coverage: `bun test --coverage`.

## Core Architecture

### Dual Routing System
The routing layer supports both compile-time and runtime route registration, both feeding into the same `matcher_core.zig` for consistency:
- **Compile-time generator** (`src/routing/generator.zig`): Analyze routes at comptime, emit static tables. Used by `quic_server.zig`. Best for performance and when routes are known at compile time.
- **Runtime dynamic matcher** (`src/routing/dynamic.zig`): Build routes at runtime via imperative API. Used by `quic_server_dyn.zig`. Best for programmatic route generation or config-driven servers.
- **Shared matcher core** (`src/routing/matcher_core.zig`): Literal/segment parsing, precedence rules, wildcard/param matching. Both generator and dynamic builder emit into the same `Segment`/`LiteralEntry`/`PatternEntry` types, ensuring HEAD fallbacks and 405 handling behave identically.
- **Routing API** (`src/routing/api.zig`): Common `FoundRoute` interface and handler signatures.

### HTTP/3 Client Architecture
Native HTTP/3 client (`src/quic/client/`) with production-ready features:
- **Main entry point**: `src/quic/client/mod.zig` exports `QuicClient`, `FetchOptions`, `ResponseEvent`, `DatagramEvent`.
- **Connection pooling**: `src/quic/client/pool.zig` manages connection reuse across requests.
- **Streaming**: Event-driven callbacks for headers, body chunks, completion, and errors.
- **WebTransport**: `src/quic/client/webtransport.zig` handles WT session negotiation, datagram queues, and client-initiated streams.
- **CLI interface**: `src/examples/h3_client.zig` provides curl-compatible output (`--curl-compat`, `--include-headers`), concurrency controls (`--repeat`, `--connections`), and DATAGRAM helpers (`--h3-dgram`, `--dgram-payload`, `--wait-for-dgrams`). Used by Bun E2E harness via `tests/e2e/helpers/zigClient.ts`.

### FFI / Bun Integration
Shared library exports (`src/ffi.zig`) enable Bun applications to embed HTTP/3 without spawning child processes:
- **Server FFI** (`src/ffi/server.zig`): `zig_h3_server_new/free/start/stop`, request/response helpers, routing registration, thread-safe callbacks for Bun.
- **Client FFI** (`src/ffi/client.zig`): `zig_h3_client_new/free/connect/fetch`, streaming/event callbacks, DATAGRAM send/receive, cancellation/timeout controls. Supports both synchronous (collect_body=1) and streaming (collect_body=0) modes.
- **Build target**: `zig build bun-ffi` produces `zig-out/lib/libzigquicheh3.{dylib,so}` and `zig-out/include/zig_h3.h`.
- **Bun usage**: `dlopen` the shared library, map FFI symbols with `bun:ffi`, use `JSCallback` with `threadsafe: true` for cross-thread event notifications.
- **Test coverage**: Worker-based FFI tests in `tests/e2e/streaming/ffi_client_streaming.worker.test.ts` and `tests/e2e/webtransport/ffi_client_webtransport.worker.test.ts`.
- **Roadmap**: See `docs/bun-ffi-plan.md` for TypeScript wrapper API design and M3/M4 milestones.

### Response API Design
HTTP response handling is split into focused modules (`src/http/response/`):
- **core.zig**: Status, header management, lifecycle (open → streaming → closed).
- **body.zig**: Whole-body writes (`write`, `writeAll`, `end`).
- **datagram.zig**: H3 DATAGRAM flow ID allocation and sending (`sendH3Datagram`).
- **streaming_ext.zig**: Range requests, chunked streaming, backpressure-aware helpers.
- Comptime status-text table (`src/http/status_codes.zig`) eliminates runtime lookups.

### Memory & Allocation Patterns
- **Arena per-request**: Each HTTP request uses an arena allocator attached to the request context; automatically freed on request completion or error.
- **Per-connection DATAGRAM buffer**: Reusable buffer up to typical MTU (1200 bytes); falls back to allocator for oversized payloads to reduce allocation churn.
- **Connection state tracking**: Per-connection counters (`active_requests`, `active_downloads`) enable stopgap gating without scanning hash tables.

### Event Loop Abstraction
- **Backend**: libev is the default; `src/net/event_loop.zig` provides a backend-agnostic API (`EventLoop`, `EventBackend` enum).
- **Watchers**: IO (UDP sockets), timers (connection timeout checks, periodic stats), signals (SIGINT/SIGTERM graceful shutdown).
- **Non-blocking UDP**: Atomic `SOCK_NONBLOCK|SOCK_CLOEXEC` flags on socket creation eliminate TOCTOU races; dual-stack binding helpers in `src/net/udp.zig`.

## Testing Architecture
Two-tier testing ensures both correctness and integration:

### Unit Tests (Zig)
- Live near code or in `src/tests.zig` using `test "…" {}`.
- Name tests with short, imperative phrases (e.g., `test "parse literal route"`).
- Run: `zig build test` or `zig test src/tests.zig`.

### E2E Tests (Bun)
- Located in `tests/e2e/`; harness uses native `h3-client` binary and FFI client.
- **Prebuild system** (`tests/e2e/helpers/prebuild.ts`): Runs `zig build h3-client` and `zig build bun-ffi` once before test suite; ensures binaries are ready.
- **Setup/teardown** (`tests/e2e/setup.ts`): Runs `prebuildAllArtifacts()` in `beforeAll`, cleans up old test files (>30 min) to prevent accumulation.
- **Server spawning** (`tests/e2e/helpers/spawnServer.ts`): Launches QUIC server as child process, waits for readiness, captures logs, kills gracefully on cleanup.
- **Client helpers**:
  - `tests/e2e/helpers/zigClient.ts`: Shells out to `./zig-out/bin/h3-client` binary with arguments, parses structured JSON output.
  - `tests/e2e/helpers/ffiClient.ts`: Low-level FFI bindings via `dlopen` for direct library testing.
- **Environment variables**:
  - `H3_VERBOSE=1`: Display all logs (default: quiet mode, only failures).
  - `H3_STRESS=1`: Enable stress variants (100+ datagram bursts, concurrent streams).
  - `H3_TEST_TIMEOUT=30000`: Override test timeout (ms) for slow CI.
  - `H3_NO_HASH=1`: Disable hash computation in server responses for faster throughput tests.
  - `H3_CHUNK_KB=64`: Set chunk size for streaming tests.
  - `H3_WEBTRANSPORT=1`: Enable WebTransport routes on server.
- **Worker tests**: Some FFI client tests run in Bun workers to test thread-safe callbacks (`.worker.test.ts` suffix).

## Coding Style & Naming Conventions
- Run `zig fmt .` before commits. 4‑space indent, no tabs.
- Filenames: `snake_case.zig`. Types: `TitleCase`. Functions/vars: `lowerCamelCase`. Use doc comments `///`.
- Keep modules small; avoid cyclic imports. Never modify `third_party/` sources.
- Zig 0.15.1+ required. Use `callconv(.c)` (lowercase `.c`). `std.ArrayList` is unmanaged in 0.15—pass an allocator (or use `std.ArrayListUnmanaged`).
- VS Code: Configure 4-space tabs for Zig files in `.vscode/settings.json`:
  ```json
  "[zig]": {
    "editor.tabSize": 4,
    "editor.insertSpaces": true,
    "editor.detectIndentation": false,
    "editor.formatOnSave": true
  }
  ```

## High-Impact Tips (for assistants)
- Build fast:
  - Initialize submodules first: `git submodule update --init --recursive`
  - Prebuild quiche once: `zig build quiche -Dquiche-profile=release`
  - Use system quiche if installed: `zig build -Dsystem-quiche=true`
  - Link libev when running server/examples: `-Dwith-libev=true -Dlibev-include=… -Dlibev-lib=…`
- Run quickly:
  - Smoke: `zig build run` (prints quiche version)
  - QUIC server: `zig build quic-server -- --port 4433 --cert third_party/quiche/quiche/examples/cert.crt --key third_party/quiche/quiche/examples/cert.key`
  - QUIC dgram echo: `zig build quic-dgram-echo -- --port 4433 --cert … --key …`
  - WebTransport stub client: `zig build wt-client -- https://127.0.0.1:4433/wt/echo`
  - Native HTTP/3 client: `./zig-out/bin/h3-client --url https://127.0.0.1:4433/ --insecure`
  - Test H3 DATAGRAMs: `./zig-out/bin/h3-client --url https://127.0.0.1:4433/h3dgram/echo --h3-dgram --dgram-payload "test" --insecure`
- Code conventions:
  - Use the `Response` API (`status`, `header`, `write`/`writeAll`, `end`, `sendTrailers`); avoid the older `sendHead/sendBody` style in docs.
  - H3 DATAGRAM: gate on peer support and use `Response.sendH3Datagram()`; route via `router.routeH3Datagram()`.
  - Never modify `third_party/` sources.
  - Run `zig fmt .` before commit.
  - Routing logic flows through `src/routing/matcher_core.zig`; add shared helpers there when extending matching rules.
- Debugging:
  - Enable qlog via server flags/config; inspect `qlogs/` outputs for handshake/flow issues.
  - If curl lacks HTTP/3, use the native h3-client: `./zig-out/bin/h3-client --url … --insecure`.
  - Client qlogs: `qlogs/client/` (clean between runs for fresh capture).
  - Verbose E2E logs: `H3_VERBOSE=1 bun test`.

## Commit & Pull Request Guidelines
- Use Conventional Commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `build:`, `chore:`. Keep subject ≤72 chars; add a body for context.
- PRs must include purpose, key changes, how to run/tests (`zig`/`cargo` commands), platform used, and relevant logs or `qlogs/` paths. Update docs if flags or behavior changed.

## Security & Configuration Tips
- Do not commit private keys; example certs live under `third_party/quiche/quiche/examples/`.
- Prefer release builds for performance: `-Dquiche-profile=release`. When linking system libs, set `-Dlink-ssl=true` and supply libev paths if used.
- Do not ever skip tests until I ask directly.