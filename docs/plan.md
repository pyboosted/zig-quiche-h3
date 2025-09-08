Implementation Plan: zig-quiche-h3

Overview
- Build the HTTP/3 server over QUIC (quiche C FFI) in 10 incremental, testable milestones. Each milestone has explicit verification criteria and keeps libev as the default event loop with an abstraction for future backends. quiche submodule is pinned to 0.24.6 for reproducibility.

Prerequisites
- Rust toolchain ≥ 1.82 (stable)
- CMake (for BoringSSL via quiche)
- Zig 0.15.1
- libev dev headers (default backend)
- Build quiche with: `cargo build --release --features ffi`

Milestone 0: Build Infrastructure (Day 1)
Status: Completed — `zig build run` and `zig build test` print quiche version (0.24.6) ✓
- Create `build.zig` linking `third_party/quiche/quiche/include` and `target/release/libquiche.a`; link `ev`.
- Minimal Zig FFI wrapper for `quiche_version()`.
- Optional: Export `zig_h3_version()` from a shared lib and call it from Bun via `dlopen` as a smoke test.
- Test:
  - `zig build` or `zig build test` prints quiche version ✓
  - (Optional) Bun `dlopen` returns version string ✓

Pre‑M1: Bun FFI Smoke Test (Completed)
- Built shared library `libzigquicheh3` exporting `zig_h3_version()` (for Bun FFI).
- Added `examples/bun/test.js`; verified output: "Quiche version from Bun: 0.24.6" ✓

Milestone 1: Event + UDP Echo (Day 2–3)
Status: Completed ✓
- Implement `EventLoop` abstraction and `EventBackend` enum { libev (default), epoll_raw, kqueue_raw, zig_io (future) }.
- Integrate libev: UDP socket readability watcher + timer; simple UDP echo (no QUIC yet).
- Test: `nc -u localhost 4433` echoes ✓

Implementation Details:
- Created `src/net/event_loop.zig` with libev backend supporting IO, timer, and signal watchers
- Implemented `src/net/udp.zig` with atomic SOCK.NONBLOCK|SOCK.CLOEXEC flags for race-free socket creation
- Added `bindAny()` helper for simplified dual-stack IPv6/IPv4 binding
- UDP echo server (`src/examples/udp_echo.zig`) demonstrates:
  - Non-blocking UDP with event-driven IO
  - Periodic timer for packet statistics (1 sec interval)
  - Signal handling (SIGINT/SIGTERM) with graceful shutdown
  - Dual-stack binding with macOS compatibility
- Performance optimizations:
  - Atomic socket flags eliminate TOCTOU races
  - Portable O_NONBLOCK using @bitOffsetOf(O, "NONBLOCK")
  - Socket buffer tuning helpers for future optimization
- Build: `zig build echo -Dwith-libev=true -Dlibev-include=$(brew --prefix libev)/include -Dlibev-lib=$(brew --prefix libev)/lib`
- Verified: Echo functionality, timer accuracy, signal handling all working correctly

Milestone 2: QUIC Handshake (Day 4–6)
Status: Completed ✓
- TLS cert/key loading; `quiche_accept()`; connection table keyed by DCID/5‑tuple.
- Enable quiche debug logging + per-connection qlog (file per connection).
- Optional: stateless retry support (configurable).
- Test:
  - `apps/quiche-client` connects successfully ✓
  - qlogs generated and readable ✓

Implementation Details:
- Created full QUIC server architecture in `src/quic/`:
  - `server.zig`: Main QuicServer with event loop integration, connection management
  - `connection.zig`: Connection abstraction with state tracking and lifecycle
  - `config.zig`: ServerConfig with TLS, ALPN, qlog, and transport parameters
- FFI bindings in `src/ffi/quiche.zig`:
  - Complete quiche API wrapper with error mapping
  - Added PacketType enum constants for readable packet type checks
  - Config, Connection, and Header abstractions
- Key features implemented:
  - TLS 1.3 certificate/key loading via quiche_config
  - Connection table using DCID as primary key with HashMap
  - Full handshake flow: Initial → Handshake → 1-RTT
  - ALPN negotiation (hq-interop for testing)
  - Dual-stack IPv6/IPv4 support with proper socket binding
  - Timer-based connection timeout management
  - Packet coalescing for efficient network usage
- QLOG support:
  - Per-connection QLOG files (JSON-SEQ format v0.3)
  - Fixed memory leak: properly free title/desc strings after setQlogPath()
  - Built quiche with "ffi,qlog" features enabled
  - Configurable via --no-qlog command line flag
- Event loop integration:
  - libev IO watcher for UDP socket events
  - Timer for connection timeout checks
  - Non-blocking packet processing with backpressure handling
- Connection lifecycle:
  - Accept new connections on Initial packets only
  - Version negotiation and unsupported version handling
  - Proper cleanup on connection close or timeout
  - Handshake completion detection and logging
- Build configuration:
  - Updated build.zig to enable qlog feature in quiche
  - Link against libev for event loop support
  - Proper include paths for quiche headers
- Testing verified:
  - quiche-client connects and completes handshake
  - QLOG files generated with valid JSON-SEQ content
  - Multiple concurrent connections handled correctly
  - Memory leak fixed and verified
  - Clean shutdown with proper resource cleanup

Milestone 3: Basic HTTP/3 (Day 7–10)
Status: Completed ✓
- Create H3 connection (`quiche_h3_conn_new_with_transport`) after QUIC established; poll events.
- Respond with static headers/body.
- Test:
  - `quiche-client` GET -> "Hello, HTTP/3!" ✓
  - Optional: `curl --http3 --insecure` returns correct headers ✓

Implementation Details:
- Created layered H3 architecture in `src/h3/`:
  - `config.zig`: H3Config wrapper with safe defaults (16KB headers, disabled QPACK)
  - `connection.zig`: H3Connection lifecycle, lazy creation after handshake
  - `event.zig`: Header collection with callback-based iteration
  - `mod.zig`: Public module exports
- Extended FFI bindings in `src/ffi/quiche.zig`:
  - Added h3 namespace with Config, Connection, Error, EventType
  - Mapped H3 error codes to Zig errors (Done, StreamBlocked are non-fatal)
  - Fixed naming conflicts with forward declarations (QuicConnection/QuicConfig)
  - Added unknown error logging for debugging
- QUIC server integration (`src/quic/server.zig`):
  - H3 connection created only when ALPN == "h3" (lazy initialization)
  - Added processH3() method for event-driven H3 handling
  - Dynamic content-length computation using std.fmt.bufPrint
  - Proper slice passing with `headers[0..]` syntax
  - H3 cleanup in closeConnection() for proper resource management
  - ALPN fallback logging for non-h3 protocols
- Zig 0.15 compatibility fixes:
  - ArrayList is unmanaged: use `std.ArrayList(T){}` initialization
  - Pass allocator to methods: `list.append(allocator, item)`
  - Calling convention: use `.c` (lowercase), not `.C`
  - Fixed C pointer types: `[*c]u8` for FFI callbacks
- Memory management:
  - Headers duplicated during collection for safe lifetimes
  - H3 connections stored as opaque pointers in QUIC connections
  - Proper cleanup chain: closeConnection → H3.deinit → free
- Testing verified:
  - quiche-client receives "Hello, HTTP/3!" correctly
  - curl --http3 shows content-length: 15 (matches body)
  - QLOG descriptions updated to "M3 - HTTP/3"
  - Multiple concurrent H3 connections handled
  - Connection cleanup without leaks

Milestone 4: Dynamic Routing (Day 11–13)
- Route registration and pattern matching (`/api/users/:id`, `/files/*`).
- Public Request/Response API (headers, status, body streaming surface started).
- Test: `/api/users/:id` returns JSON; correct headers/status ✓

Milestone 5: Streaming Bodies (Day 14–16)
- Chunked read/write with backpressure; partial write handling (`Done` retry).
- Test: upload/download 1 GiB with checksums; no leaks; backpressure observed ✓

Milestone 6: QUIC DATAGRAM (Day 17–19)
- Enable QUIC DATAGRAM; send/recv APIs; queue sizing and purge.
- Test: QUIC datagram echo endpoint; disabled-path returns error ✓

Milestone 7: H3 DATAGRAM (Day 20–22)
- Gate on `quiche_h3_dgram_enabled_by_peer()`; implement H3 flow‑id varint mapping for request association.
- Test: request-associated datagram echo; flow‑id routing verified ✓

Milestone 8: WebTransport (Experimental) (Day 23–25)
- Extended CONNECT session management (`:protocol = webtransport`).
- Session‑bound DATAGRAMs (session id = CONNECT stream id). No WT streams yet (blocked by C FFI).
- Test:
  - CLI test client performs WT handshake; session DATAGRAM echo ✓
  - Stretch: browser WT handshake with trusted cert/Alt‑Svc ✓

Milestone 9: Interop + Performance (Day 26–28)
- Quick interop sanity with another stack (e.g., ngtcp2/quic-go) on basic H3 routes.
- Metrics + qlog hooks; pacing/params tuning; initial throughput/latency targets.
- Test:
  - Interop basic success ✓
  - 10k req/s benchmark target on loopback ✓

Milestone 10: Bun FFI (Day 29–30)
- Export thin C ABI for Bun (`zig_h3_server_new/start/stop`, routing, response, datagrams, WT session DATAGRAMs, `zig_h3_version`).
- JS example using `bun:ffi` (`dlopen`, `JSCallback` or polling mode) to run server and handle requests.
- Test: Run server from Bun; receive responses; clean shutdown ✓

Acceptance Gates
- QUIC/H3: Handshake success; qlogs readable; event loop drives send/recv correctly.
- DATAGRAM: QUIC and H3 DATAGRAMs behave; H3 flow‑id mapping verified.
- WebTransport: CONNECT + `:protocol = webtransport` accepted; session DATAGRAM roundtrip; clear limitations documented.
- Bun FFI: No cross‑thread crashes; `JSCallback` marked `threadsafe: true` or polling mode; proper teardown.

Notes
- Default event backend: libev; epoll/kqueue backends are available via compile‑time flag; future `zig_io` backend when stable.
- Spec clarifies C FFI realities: no H3 DATAGRAM event; WebTransport streams not exposed via C FFI.
- quiche submodule pinned to 0.24.6.
