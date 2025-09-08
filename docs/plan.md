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
- Create `build.zig` linking `third_party/quiche/quiche/include` and `target/release/libquiche.a`; link `ev`.
- Minimal Zig FFI wrapper for `quiche_version()`.
- Optional: Export `zig_h3_version()` from a shared lib and call it from Bun via `dlopen` as a smoke test.
- Test:
  - `zig build` or `zig build test` prints quiche version ✓
  - (Optional) Bun `dlopen` returns version string ✓

Milestone 1: Event + UDP Echo (Day 2–3)
- Implement `EventLoop` abstraction and `EventBackend` enum { libev (default), epoll_raw, kqueue_raw, zig_io (future) }.
- Integrate libev: UDP socket readability watcher + timer; simple UDP echo (no QUIC yet).
- Test: `nc -u localhost 4433` echoes ✓

Milestone 2: QUIC Handshake (Day 4–6)
- TLS cert/key loading; `quiche_accept()`; connection table keyed by DCID/5‑tuple.
- Enable quiche debug logging + per-connection qlog (file per connection).
- Optional: stateless retry support (configurable).
- Test:
  - `apps/quiche-client` connects successfully ✓
  - qlogs generated and readable ✓

Milestone 3: Basic HTTP/3 (Day 7–10)
- Create H3 connection (`quiche_h3_conn_new_with_transport`) after QUIC established; poll events.
- Respond with static headers/body.
- Test:
  - `quiche-client` GET -> "Hello, HTTP/3!" ✓
  - Optional: `curl --http3-only --insecure` returns OK ✓

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

