Implementation Plan: zig-quiche-h3

Overview
- Build the HTTP/3 server over QUIC (quiche C FFI) in 10 incremental, testable milestones. Each milestone has explicit verification criteria and keeps libev as the default event loop with an abstraction for future backends. quiche submodule is pinned to 0.24.6 for reproducibility.

Prerequisites
- Rust toolchain ≥ 1.82 (stable)
- CMake (for BoringSSL via quiche)
- Zig 0.15.1
- libev dev headers (default backend)
- Build/run via Zig:
  - `git submodule update --init --recursive`
  - `zig build quiche -Dquiche-profile=release` (optional; also runs implicitly)
  - `zig build` (smoke app prints quiche version)
  - Use system quiche: `zig build -Dsystem-quiche=true`
  - Common flags: `-Dwith-libev=true -Dlibev-include=… -Dlibev-lib=…`, `-Dlink-ssl=true`

Milestone 0: Build Infrastructure (Day 1)
Status: Completed — `zig build run` and `zig build test` print quiche version (0.24.6) ✓
- Implement `build.zig` that can either build vendored quiche via Cargo (`zig build quiche`, with `-Dquiche-profile`) or link a system quiche (`-Dsystem-quiche=true`).
- Add libev toggle `-Dwith-libev=true` and include/lib path flags.
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
Status: Completed ✓
- Route registration and pattern matching (`/api/users/:id`, `/files/*`).
- Public Request/Response API (headers, status, body streaming surface started).
- Type-safe JSON serialization using `std.json.Stringify.valueAlloc()`.
- Test: `/api/users/:id` returns JSON; correct headers/status ✓

Implementation Details:
- Created HTTP abstraction layer in `src/http/`:
  - `router.zig`: Path-based routing with parameter extraction (`:id` patterns)
  - `request.zig`: Request object with headers, params, arena allocator
  - `response.zig`: Response builder with status, headers, body methods
  - `json.zig`: Type-safe JSON serialization using std.json API
- Router features:
  - Pattern matching for static paths and parameters (`:id`)
  - Wildcard support (`/files/*`)
  - Method-specific routing (GET, POST, etc.)
  - Parameter extraction into request.params
- Request/Response API:
  - Request: method, path, headers, params, body access
  - Response: chainable status(), header(), write(), end() methods
  - Arena allocator per request for zero-cost cleanup
- JSON serialization:
  - `json.send()`: Serialize any Zig value to JSON response
  - `jsonValue()` method on Response for structured data
  - Uses `std.json.Stringify.valueAlloc()` (Zig 0.15.1 API)
  - Minified output for bandwidth efficiency
  - Proper charset specification in content-type header
- Memory optimizations:
  - Eliminated double header duplication in server.zig
  - Headers directly referenced from arena-allocated memory
  - Single allocation per JSON response using arena
- Configuration validation:
  - Added debug_log_throttle > 0 validation at startup
  - Early error detection prevents runtime issues
- Example handlers:
  - `/api/users`: Returns JSON array of users
  - `/api/users/:id`: Returns single user object with ID
  - `/api/echo`: Echoes POST body back as JSON
  - `/files/*`: Serves static files (future implementation)
- Testing verified:
  - JSON responses properly formatted and escaped
  - Content-type includes charset=utf-8
  - Dynamic routes with parameters working
  - Memory efficient with arena cleanup

Milestone 5: Streaming Bodies (Day 14–16)
Status: Completed ✓
- Chunked read/write with backpressure; partial write handling (`Done` retry).
- Push-mode callbacks for streaming request bodies without buffering.
- Test: upload/download 1 GiB with checksums; no leaks; backpressure observed ✓

Implementation Details:
- Created comprehensive streaming layer in `src/http/streaming.zig`:
  - PartialResponse abstraction for resumable sends with three source types (memory/file/generator)
  - BlockedStreams tracking for efficient backpressure management
  - Chunk-based processing with configurable sizes (default 256KB, tunable via H3_CHUNK_KB)
  - Zero-copy file streaming with pread for efficiency
  - Generator-based streaming to avoid blocking the event loop
- Extended Response API with streaming methods:
  - `writeAll()` for small handlers with automatic retry on StreamBlocked
  - `sendFile()` for zero-copy file streaming with MIME type detection
  - `processPartialResponse()` for resuming blocked sends
  - Proper FIN handling for stream completion
- Server enhancements for streaming:
  - `processWritableStreams()` method for resuming blocked streams
  - Proper .Finished event handling (keeps state alive if response ongoing)
  - Stream writability tracking with `streamWritable()` hints
  - Memory-bounded request body tracking (counter, not ArrayList)
- Example streaming handlers implemented:
  - `/download/*`: File streaming with path traversal safety
  - `/stream/1gb`: Generator-based 1GB test stream (no memory allocation)
  - `/stream/test`: 10MB test with checksum validation (optional via H3_NO_HASH)
- Critical fixes implemented:
  - Fixed premature state cleanup on .Finished when response still streaming
  - Memory-efficient body size tracking without allocation
  - Defensive null setting after partial.deinit()
  - All handlers use writeAll() to prevent truncation
  - **FIN packet properly sent for large transfers (fixed connection hanging)**
  - Stream completion signaling correctly implemented
- Push-mode streaming callbacks for request bodies:
  - Extended handler.zig with OnHeaders/OnBodyChunk/OnBodyComplete callbacks
  - Callbacks receive Response pointer for bidirectional streaming
  - Router support via routeStreaming() method for registering callbacks
  - Server invokes callbacks at appropriate H3 events (Headers/Data/Finished)
  - Example implementations: `/upload/stream` (SHA-256), `/upload/echo` (bidirectional)
  - Zero memory allocation for arbitrarily large uploads
- Performance optimizations:
  - Build with `-Doptimize=ReleaseFast` critical for streaming performance
  - Configurable chunk sizes via environment variables
  - Optional SHA-256 computation for benchmarking
- Testing verified:
  - 1GB downloads complete without memory exhaustion (~16s with proper FIN)
  - Backpressure properly handled with StreamBlocked/Done errors
  - Multiple concurrent streams work correctly
  - No premature state cleanup during streaming
  - Stream capacity properly restored after backpressure
  - Push-mode callbacks invoked correctly for uploads
  - SHA-256 computation on-the-fly without buffering
  - Connection properly closes after large transfers

Milestone 5+: Bun E2E Testing Environment (Day 16–17)
Status: Completed ✓
- Comprehensive E2E testing framework using Bun orchestration + curl HTTP/3 client
- Fast test runner with TypeScript support for modern testing experience
- Reference: `docs/bun-testing-env.md` for complete framework design
- Test categories:
  - Basic HTTP/3: routes, headers, status codes, content types
  - Streaming downloads: integrity checks, large files (1GB+)
  - Streaming uploads: checksums, size validation, push-mode handling
  - Backpressure testing: concurrent connections, partial writes
- Implementation components:
  - Server lifecycle helper (build, spawn, probe, cleanup) in `tests/e2e/helpers/`
  - Random port selection to avoid conflicts in CI
  - Readiness probing via curl HEAD requests
  - Automatic server teardown on test completion
  - Structured curl client wrapper with response parsing
- Test harness features:
  - `curlClient.ts`: Structured HTTP/3 client with typed responses
  - `spawnServer.ts`: Server lifecycle management with automatic port allocation
  - `testUtils.ts`: File generation, temp directories, content-length parsing
  - Support for stress testing via H3_STRESS=1 environment variable
- Benefits:
  - Validates all M5 streaming features comprehensively
  - Tests real HTTP/3 client behavior (not just unit tests)
  - Fast iteration with clear, debuggable failures
  - Hermetic tests suitable for CI/CD pipelines
- Test results:
  - **49 tests passing**, 1 conditionally skipped
  - All streaming tests pass including 1GB downloads/uploads
  - Rate-limited tests work with 30MB/s throttling
  - Concurrent uploads/downloads handle correctly
  - FIN packet issues resolved, connections close properly
- Test execution:
  - `bun test tests/e2e` runs full suite (~10s)
  - `H3_STRESS=1 bun test` includes stress tests (~55s)
  - Individual test files for focused debugging
  - QLOG disabled by default for performance
  - Note: curl must include HTTP/3 support for these tests; if unavailable, use `third_party/quiche` client binaries as an alternative.

Milestone 5.5: HTTP Range Requests (Day 17–18)
Status: Completed ✓
- RFC 7233 compliant byte-range support for resumable downloads ✓
- Single-range implementation for files and known-size responses ✓
- Parser with typed errors for precise policy decisions ✓
- Integration with existing PartialResponse streaming ✓
- Test:
  - Range parser unit tests with boundary cases ✓
  - 206 Partial Content with Content-Range headers ✓
  - 416 Range Not Satisfiable for invalid ranges ✓
  - HEAD request parity with GET ✓
  - curl --range E2E tests via Bun ✓
- Implementation completed with all review feedback addressed:
  - Fixed 416 Content-Range format to "bytes */size" per RFC 7233
  - Added Content-Length: 0 for 416 responses
  - Fixed type conversions and header constant usage
  - Created comprehensive E2E test suite (18 tests)

Milestone 6: QUIC DATAGRAM (Day 19–21)
Status: Completed ✓
- Enable QUIC DATAGRAM; send/recv APIs; queue sizing and purge.
- Implementation details:
  - `QuicServer.onDatagram(cb, user)` registers a connection-scoped callback
  - `QuicServer.sendDatagram(conn, data)` respects `dgramMaxWritableLen()` and backpressure (`error.WouldBlock`)
  - Counters for sent/dropped datagrams maintained in server
- Tests:
  - QUIC datagram echo endpoint (see `src/examples/quic_dgram_echo.zig`)
  - E2E: `tests/e2e/basic/dgram.test.ts`

Milestone 7: H3 DATAGRAM (Day 20–22)
Status: Completed ✓
- Gate on `quiche_h3_dgram_enabled_by_peer()`; implement H3 flow‑id varint mapping for request association.
- Implementation details:
  - Route-level callback via `router.routeH3Datagram(method, pattern, cb)`
  - `Response.sendH3Datagram(payload)` encodes flow-id varint + payload and sends via QUIC DATAGRAM
  - Flow-id mapping derived from request stream id, with CONNECT and CONNECT-UDP handling
- Tests:
  - Request-associated datagram echo; flow‑id routing verified
  - E2E: `tests/e2e/basic/h3_dgram.test.ts`

Milestone 8: WebTransport (Experimental) (Day 23–25)
Status: Planned
- Extended CONNECT session management (`:protocol = webtransport`).
- Session‑bound DATAGRAMs (session id = CONNECT stream id). No WT streams yet (blocked by C FFI).
- Tests (planned):
  - CLI test client performs WT handshake; session DATAGRAM echo
  - Stretch: browser WT handshake with trusted cert/Alt‑Svc

Milestone 9: Interop + Performance (Day 26–28)
Status: Planned
- Quick interop sanity with another stack (e.g., ngtcp2/quic-go) on basic H3 routes.
- Metrics + qlog hooks; pacing/params tuning; initial throughput/latency targets.
- Tests (targets):
  - Interop basic success
  - 10k req/s benchmark target on loopback

Milestone 10: Bun FFI (Day 29–30)
Status: Planned (partial smoke test done)
- Export thin C ABI for Bun (`zig_h3_server_new/start/stop`, routing, response, datagrams, WT session DATAGRAMs, `zig_h3_version`).
- JS example using `bun:ffi` (`dlopen`, `JSCallback` or polling mode) to run server and handle requests.
- Test: Run server from Bun; receive responses; clean shutdown

Acceptance Gates
- QUIC/H3: Handshake success; qlogs readable; event loop drives send/recv correctly.
- DATAGRAM: QUIC and H3 DATAGRAMs behave; H3 flow‑id mapping verified.
- WebTransport: CONNECT + `:protocol = webtransport` accepted; session DATAGRAM roundtrip; clear limitations documented.
- Bun FFI: No cross‑thread crashes; `JSCallback` marked `threadsafe: true` or polling mode; proper teardown.

Notes
- Default event backend: libev; epoll/kqueue backends are available via compile‑time flag; future `zig_io` backend when stable.
- Spec clarifies C FFI realities: no H3 DATAGRAM event; WebTransport streams not exposed via C FFI.
- quiche submodule pinned to 0.24.6.
 - E2E tests reference:
   - Basic DATAGRAM: `tests/e2e/basic/dgram.test.ts`
   - H3 DATAGRAM: `tests/e2e/basic/h3_dgram.test.ts`
   - Trailers: `tests/e2e/basic/trailers.test.ts`
