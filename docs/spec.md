Below is a **complete technical specification** for a Zig 0.15.1 library that exposes an HTTP/3 server running over QUIC, **backed by Cloudflare’s Rust `quiche`** (through its stable C FFI). I keep the public Zig API idiomatic and **model the usage patterns you see in the Rust examples** (accept, recv/send loop, `h3::Connection::with_transport`, `poll`, `send_response`, `send_body`, etc.), while hiding transport and H3 details behind server configuration, endpoint routing, and datagram hooks, as you requested.

Where relevant I cite `quiche` sources and docs so you can jump straight to the code or the docstring that inspired the design.

---

## 1) Scope & goals

**Goal.** Provide a Zig library, `zig-quiche-h3`, that:

* Runs an **HTTP/3 server over QUIC** on POSIX systems (Linux, macOS, \*BSD); **Windows out of scope in phase 1**.
* Is implemented in Zig 0.15.1, linking to `quiche` via its **C FFI** (static or shared).
* Exposes a **simple, “Rust-example-like”** API to configure the server and define:

  * server parameters (TLS, QUIC transport, H3 settings),
  * **HTTP endpoints/handlers** for request/response streaming,
  * **HTTP/3 Datagram** (QUIC DATAGRAM) callbacks.
* Provides **full HTTP/3 support to the extent `quiche` exposes it**: ALPN `h3`, HTTP/3 handshake & control streams, QPACK, headers/data/trailers, GOAWAY, priority update, stats, and HTTP/3 DATAGRAMs (when negotiated). (See `quiche::h3` module and the `Connection` methods and events we mirror. ([QUIC Docs][1]))
* Adds initial, experimental support for **WebTransport over HTTP/3**: accept/establish sessions via Extended CONNECT and support session-bound DATAGRAMs. Note: peer-initiated WebTransport streams are not surfaced by the current `quiche` C FFI; stream support is limited (see 5.7). WebTransport is compiled in by default; you can opt out at build time.
* Ships with a comprehensive test suite and **bench harness**, and includes interop & conformance tests using `quiche`’s own apps/tools and the community **QUIC Interop Runner**. ([Docs.rs][2], [GitHub][3])

**Non-goals (phase 1).**

* Windows support.
* HTTP/3 server push (rarely used; Chromium removed H2 push, many stacks dropped H3 push; `quiche::h3::Connection` doesn’t expose push APIs in current docs). ([QUIC Docs][4], [Chrome for Developers][5], [mailman.nginx.org][6])
* Reverse proxy features (MASQUE tunneling can be explored later).
* Full WebTransport stream support (bi/uni streams). We only support session establishment and DATAGRAMs initially; peer-initiated WebTransport streams are ignored by `quiche`’s H3 parser and not exposed via the C FFI, so this is blocked on upstream.

---

## 2) External dependencies & versions

* **Zig**: 0.15.1. ([Zig Programming Language][7])
* **quiche**: 0.24.6 (pinned submodule). Build with **`--features ffi`** to export the C ABI (`libquiche.a`), optionally **`pkg-config-meta`** for `quiche.pc`. `quiche` offers an **HTTP/3 module** (`quiche::h3`) and a **thin C API** in `include/quiche.h`. ([Docs.rs][2])
* **TLS**: `quiche` uses **BoringSSL** by default (auto-built by Cargo) or can be built with **quictls/openssl** feature (0‑RTT not supported with openssl vendor). We follow `quiche` choice. ([Docs.rs][2])
* **libev**: used as the default event loop backend (mirrors quiche C examples); alternative raw epoll/kqueue backend remains an option. Link as a system library (`ev`). Example binaries that depend on the event loop are only built when you pass `-Dwith-libev=true`.

---

## 3) Build & link model

**Recommended layout**

```
/zig-quiche-h3
  /build.zig
  /src
    /ffi/ (imported quiche.h + Zig wrappers)
    /net/ (socket, epoll/kqueue, timers, batching)
    /quic/ (conn map, accept/recv/send, pacing, qlog)
    /h3/ (h3 state, routing, body streams, trailers)
    /dgram/ (QUIC DATAGRAM + H3 DATAGRAM glue)
    /util/ (alloc, arena buffers, vectors)
  /tests
  /benches
```

**Build prerequisites**

* Rust toolchain ≥ 1.82 (stable)
* CMake (required to build BoringSSL vendored by quiche)
* Zig 0.15.1
* libev development headers (for default backend; e.g., `libev-dev` on Debian/Ubuntu, `brew install libev` on macOS)

**Build steps (in-repo)**

1) Initialize submodules (quiche vendored under `third_party/`):

```bash
git submodule update --init --recursive
```

2) Build everything via Zig (Cargo run for quiche is handled by `build.zig`):

```bash
# Build quiche staticlib first (optional: also happens implicitly on full build)
zig build quiche -Dquiche-profile=release

# Build the project (prints quiche version as a smoke test)
zig build

# Run the smoke app
zig build run
```

3) Use a system-installed quiche instead of the vendored submodule:

```bash
zig build -Dsystem-quiche=true
```

Common flags:

- `-Dquiche-profile=release|debug` to select Cargo profile when building vendored quiche.
- `-Dwith-libev=true -Dlibev-include=… -Dlibev-lib=…` to link libev and build example binaries (server, echo, etc.). Without this flag, examples are skipped, and core library/tests still build.
- `-Dwith-webtransport=false|true` to toggle WebTransport features (default: true).
- `-Dlink-ssl=true` when linking against OpenSSL/quictls instead of vendored BoringSSL.
- `-Dlog-level=error|warn|info|debug|trace` to set the compile-time logging floor (default: `warn`).

Examples and tests:

- UDP echo: `zig build echo` (send with `nc -u localhost 4433`).
- QUIC server example (requires `-Dwith-libev=true`): `zig build quic-server -- --port 4433 --cert third_party/quiche/quiche/examples/cert.crt --key third_party/quiche/quiche/examples/cert.key`.
  - Examples now share a struct-based argument parser (`src/args.zig`): declare a struct, call `args.Parser(MyArgs).parse()`, and get automatic `--help` output plus short/long flag support.
- Unit tests: `zig build test` or `zig test src/tests.zig`.

> **Why C FFI (not Rust JNI/`extern "Rust"`)?** The `quiche` team officially supports a **thin C API** consistent with the Rust API. Zig’s C-ABI interop is first-class and stable, so this is the cleanest, most robust bridge. ([GitHub][8])

---

## 4) Public Zig API (modeled after `quiche` examples)

### 4.1 Core types (public)

```zig
pub const Server = struct {
    pub fn init(allocator: *std.mem.Allocator, cfg: ServerConfig) !*Server;
    pub fn deinit(self: *Server) void;

    /// Starts IO loop and runs until stop() or fatal error.
    pub fn run(self: *Server) !void;

    /// Async-safe stop request (e.g. signal handler).
    pub fn stop(self: *Server) void;

    /// Register HTTP route handlers before run().
    pub fn route(self: *Server, method: Method, pattern: []const u8, handler: HttpHandler) !void;

    /// Register a QUIC DATAGRAM handler (connection-scoped, not HTTP-routed).
    /// For HTTP/3 DATAGRAM associated to requests, attach callbacks via router.routeH3Datagram().
    pub fn onDatagram(self: *Server, cb: OnDatagram, user: ?*anyopaque) void;

    /// Register WebTransport handler for CONNECT + :protocol=webtransport (experimental/planned).
    pub fn webtransport(self: *Server, pattern: []const u8, handler: WebTransportHandler) !void;
};

pub const ServerConfig = struct {
    pub const LogLevel = enum(u8) { err, warn, info, debug, trace };

    // Network / TLS
    bind_addr: []const u8 = "0.0.0.0",
    bind_port: u16 = 4433,
    cert_path: []const u8 = "third_party/quiche/quiche/examples/cert.crt",
    key_path: []const u8 = "third_party/quiche/quiche/examples/cert.key",
    verify_peer: bool = false,

    // QUIC transport defaults (mirror src/quic/config.zig)
    idle_timeout_ms: u64 = 30_000,
    initial_max_data: u64 = 2 * 1024 * 1024,
    initial_max_stream_data_bidi_local: u64 = 1 * 1024 * 1024,
    initial_max_stream_data_bidi_remote: u64 = 1 * 1024 * 1024,
    initial_max_stream_data_uni: u64 = 1 * 1024 * 1024,
    initial_max_streams_bidi: u64 = 10,
    initial_max_streams_uni: u64 = 10,
    max_recv_udp_payload_size: usize = 1350,
    max_send_udp_payload_size: usize = 1350,
    disable_active_migration: bool = true,
    enable_pacing: bool = true,
    cc_algorithm: []const u8 = "cubic",
    enable_dgram: bool = false,
    dgram_recv_queue_len: usize = 0,
    dgram_send_queue_len: usize = 0,
    grease: bool = true,

    // Logging & diagnostics
    qlog_dir: ?[]const u8 = "qlogs",
    keylog_path: ?[]const u8 = null,
    enable_debug_logging: bool = true,
    log_level: LogLevel = .warn,
    debug_log_throttle: u32 = 10,

    // ALPN set (HTTP/3 + fallback interop protocols)
    alpn_protocols: []const []const u8 = &.{
        "h3",
        "hq-interop",
        "hq-29",
        "hq-28",
        "hq-27",
        "http/0.9",
    },

    // HTTP limits & validation
    max_request_headers_size: usize = 16_384,
    max_request_body_size: usize = 100 * 1024 * 1024,
    max_path_length: usize = 2048,
    max_header_count: usize = 100,
    max_header_name_length: usize = 256,
    max_header_value_length: usize = 8192,
    max_non_streaming_body_bytes: usize = 1 * 1024 * 1024,
    max_active_requests_per_conn: usize = 0,
    max_active_downloads_per_conn: usize = 0,

    // WebTransport knobs (experimental; guarded by -Dwith-webtransport)
    wt_max_streams_uni: u32 = 32,
    wt_max_streams_bidi: u32 = 32,
    wt_write_quota_per_tick: usize = 64 * 1024,
    wt_session_idle_ms: u64 = 60_000,
    wt_stream_pending_max: usize = 256 * 1024,
    wt_app_err_stream_limit: u64 = 0x1000,
    wt_app_err_invalid_stream: u64 = 0x1001,

    // Retry & buffers
    enable_retry: bool = false,
    recv_buffer_size: usize = 2048,
    send_buffer_size: usize = 2048,

    /// Compile-time validation mirrors src/quic/config.zig.validateComptime()
    /// (port range, ALPN length, header limits, buffer sizing, etc.).
    pub fn validateComptime(comptime cfg: ServerConfig) void { /* compile-time asserts */ }
    /// Runtime validation is available via validate().
};

pub const Request = struct {
    method: Method,
    path: []const u8,
    authority: []const u8,
    headers: []Header,
    body: BodyReader,          // streaming read
    conn_id: u64,              // tie back to connection for server-state
};

pub const Response = struct {
    /// Set status and add headers before sending body
    pub fn status(self: *Response, code: u16) !void;
    pub fn header(self: *Response, name: []const u8, value: []const u8) !void;
    /// Write helpers
    pub fn write(self: *Response, data: []const u8) !usize;
    pub fn writeAll(self: *Response, data: []const u8) !void;
    /// Finish the response (optionally with a final chunk)
    pub fn end(self: *Response, final: ?[]const u8) !void;
    /// Send HTTP/3 trailers and finish the stream
    pub fn sendTrailers(self: *Response, trailers: []const Trailer) !void;
    /// Send an H3 DATAGRAM associated with this request (if negotiated)
    pub fn sendH3Datagram(self: *Response, payload: []const u8) !void;
};

// Typed error unions are used across the API for compile-time safety.
// See: HandlerError, StreamingError, DatagramError, WebTransportError.
pub const HttpHandler = *const fn (*Request, *Response) HandlerError!void;

/// HTTP/3 DATAGRAM callback associated to a request route
pub const OnH3Datagram = *const fn (*Request, *Response, []const u8) DatagramError!void;
/// QUIC DATAGRAM callback (connection-scoped)
pub const OnDatagram = *const fn (*Server, *Connection, []const u8, ?*anyopaque) DatagramError!void;

// Error types used by handlers and callbacks
pub const HandlerError = error{
    HeadersAlreadySent,
    ResponseEnded,
    StreamBlocked,
    InvalidState,
    PayloadTooLarge,
    NotFound,
    MethodNotAllowed,
    BadRequest,
    Unauthorized,
    Forbidden,
    RequestTimeout,
    TooManyRequests,
    InternalServerError,
    RequestHeaderFieldsTooLarge,
    RangeNotSatisfiable,
    InvalidRange,
    Unsatisfiable,
    Malformed,
    MultiRange,
    NonBytesUnit,
    InvalidRedirectStatus,
    OutOfMemory,
};
pub const StreamingError = error{
    StreamBlocked,
    ResponseEnded,
    HeadersAlreadySent,
    InvalidState,
    PayloadTooLarge,
    OutOfMemory,
};
pub const DatagramError = error{
    WouldBlock,
    DatagramTooLarge,
    ConnectionClosed,
    Done,
    OutOfMemory,
};
pub const WebTransportError = error{
    SessionClosed,
    StreamBlocked,
    InvalidState,
    WouldBlock,
    OutOfMemory,
};
pub const WebTransportStreamError = error{
    StreamClosed,
    StreamReset,
    FlowControl,
    WouldBlock,
    InvalidState,
    OutOfMemory,
};
pub const GeneratorError = error{
    EndOfStream,
    ReadError,
    OutOfMemory,
};

pub fn errorToStatus(err: HandlerError || StreamingError || DatagramError || WebTransportError || WebTransportStreamError || GeneratorError) u16;

/// Event backend abstraction to allow swapping libev / raw epoll/kqueue /
/// (future) Zig std.io based loops without changing the public API.
pub const EventBackend = enum {
    libev,      // Default, proven, mirrors quiche C examples
    epoll_raw,  // Linux-specific optimization
    kqueue_raw, // macOS/BSD optimization
    zig_io,     // Future: when Zig >= 0.16 I/O matures
};

pub const EventLoop = struct {
    backend: EventBackend,
    // Implementation detail: we use comptime dispatch for the selected
    // backend where possible, otherwise a small vtable of function pointers
    // for init/register/readable/timer/run/stop.
};

// Experimental: WebTransport (limited)
pub const WebTransportSession = struct {
    /// Session identifier (maps to CONNECT request stream ID per WT over H3).
    session_id: u64,
    /// Original CONNECT request headers.
    request_headers: []Header,

    /// Send a session-bound DATAGRAM (requires H3 DATAGRAM + peer support).
    pub fn sendDatagram(self: *WebTransportSession, payload: []const u8) !void;

    /// Close the session (sends GOAWAY or closes the CONNECT stream).
    pub fn close(self: *WebTransportSession, code: u64, reason: []const u8) !void;
};

pub const WebTransportHandler = fn (req: *Request, sess: *WebTransportSession) WebTransportError!void;
```

**Notes & mapping to `quiche`:**

* We impersonate `quiche`’s runtime pattern: **create QUIC config**, accept/recv, then construct **`h3::Connection::with_transport()`** and **`poll()` for events** (Headers/Data/Finished/PriorityUpdate/GoAway). We hide that behind the server loop and invoke your registered handlers. ([QUIC Docs][1])
* `Response.sendTrailers()` maps to **`send_additional_headers(..., is_trailer_section=true)`** in `quiche::h3::Connection`. ([QUIC Docs][4])
* **Datagrams**: We expose QUIC DATAGRAM and **HTTP/3 DATAGRAM** integration (when negotiated). You can test availability using `h3_conn.dgram_enabled_by_peer(conn)`; we do this internally, surfacing a runtime capability and returning an error if you try to send before it’s enabled. ([QUIC Docs][9])

### 4.2 “Hello H3” example (library UX)

```zig
var server = try Server.init(allocator, .{
    .bind_addr = "0.0.0.0:443",
    .cert_chain_pem = "certs/server.crt",
    .priv_key_pem   = "certs/server.key",
    .quic = .{ .alpn = &.{ "h3" }, .enable_datagrams = true },
    .h3   = .{ .qpack_max_table_capacity = 4096 },
    .qlog_dir = "/var/log/quic",
});

// Simple GET endpoint.
try server.route(.GET, "/hello", struct {
    pub fn handler(_: *Request, res: *Response) HandlerError!void {
        try res.status(200);
        try res.header("content-type", "text/plain");
        try res.writeAll("Hello, HTTP/3!\n");
        try res.end(null);
    }
}.handler);

// QUIC DATAGRAM echo (connection-scoped)
server.onDatagram(struct {
    fn dgramEcho(srv: *Server, conn: *Connection, payload: []const u8, _: ?*anyopaque) DatagramError!void {
        // Best-effort echo; drop if backpressured
        srv.sendDatagram(conn, payload) catch |err| switch (err) {
            error.WouldBlock => {},
            else => return err,
        };
    }
}.dgramEcho, null);

// HTTP/3 DATAGRAM echo bound to a request route
try server.route(.GET, "/h3dgram/echo", struct {
    pub fn handler(_: *Request, res: *Response) HandlerError!void {
        // Normal response body or just headers; H3 dgrams handled by callback below
        try res.status(200);
        try res.header("content-type", "text/plain");
        try res.writeAll("h3 dgram route active\n");
        try res.end(null);
    }
}.handler);
try server.router.routeH3Datagram(.GET, "/h3dgram/echo", struct {
    pub fn onDgram(_: *Request, res: *Response, payload: []const u8) DatagramError!void {
        // Echo back via request-associated H3 DATAGRAM
        res.sendH3Datagram(payload) catch |err| switch (err) {
            error.WouldBlock => {}, // drop on backpressure
            else => return err,
        };
    }
}.onDgram);

try server.run();
```

This mirrors the **Rust example flow**—application configures QUIC/H3, `with_transport()`, then handles **`h3::Event`** with `send_response`, `send_body`, `send_additional_headers` as needed. We encapsulate the loop so the app only declares endpoints/handlers. ([QUIC Docs][1])

---

## 5) Internals & mapping to quiche

### 5.1 FFI layer

* Import **`include/quiche.h`** and wrap the subset we need:

  * `quiche_config_new`, `quiche_config_set_application_protos`, initial limits setters, `*_load_cert_chain_from_pem_file`, `*_load_priv_key_from_pem_file`, congestion, `quiche_config_enable_dgram`, etc.
  * Server-side create/drive connections: `quiche_accept`, `quiche_conn_recv`, `quiche_conn_send`, `quiche_conn_close`, timers (`quiche_conn_timeout_as_nanos/conn_on_timeout`), stats.
  * **HTTP/3**: `quiche_h3_config_new`, `quiche_h3_conn_new_with_transport`, `quiche_h3_conn_poll`, `quiche_h3_send_response`, `quiche_h3_send_body`, `quiche_h3_recv_body`, `quiche_h3_event_*` helpers, possibly `quiche_h3_send_additional_headers` if exposed (Rust has it; C API mirrors Rust). You can see these used in the C examples. ([Docs.rs][10])
  * DATAGRAM: Use `quiche_conn_dgram_send/recv` for QUIC DATAGRAM frames. H3 DATAGRAM is negotiated via SETTINGS, but the C FFI does not expose a dedicated H3 DATAGRAM event. When `quiche_h3_dgram_enabled_by_peer(conn)` is true, encode/decode the H3 flow ID (varint) in the DATAGRAM payload to associate datagrams with requests, mirroring the pattern used in quiche’s apps. ([QUIC Docs][9])
* Memory ownership: every `quiche_*_new()` has a matching `quiche_*_free()`. We encapsulate finalizers in Zig and call in `Server.deinit()`.

> References
> – C header `include/quiche.h` (functions listed above). ([Docs.rs][12])
> – C examples `http3-client.c`, `http3-server.c` for `quiche_h3_conn_new_with_transport`, `quiche_h3_conn_poll`, events, `send_response`, `send_body`. ([Docs.rs][10], [GitLab][13])

### 5.2 Transport & eventing

* **UDP socket** on POSIX; set **non-blocking**; use **`recvmmsg`/`sendmmsg`** when available for batching; fallback to `recvfrom/sendto`.
* **Event loop**:

  * Abstraction: `EventLoop` with `EventBackend = { libev, epoll_raw, kqueue_raw, zig_io }`.
  * Default: **libev** watchers for UDP readability and periodic timers (mirrors quiche’s C examples). We schedule TX respecting `send_info.at` via timers.
  * Alternatives: raw **epoll**/**kqueue** backends via compile-time selection; **zig_io** reserved for future Zig once stable.
  * Avoid using Zig’s evolving std.net; prefer stable C ABI (libev) or raw POSIX.
* **Timers**: each connection’s `timeout()` (exposed via C API) schedules a timer; on expiry call `conn_on_timeout()` and re-run send loop. (See `quiche` readme on timers & `SendInfo.at` for pacing hints.) ([Docs.rs][2])
* **Pacing**: use `SendInfo.at` hints from `quiche_conn_send()` to schedule TX as recommended (optionally integrate Linux `SO_TXTIME`/ETF). ([Docs.rs][2])

### 5.3 Accepting new connections

* On receiving an Initial, parse header (C API has header parser), call **`quiche_accept()`** with generated SCID and server config; store in a connection table keyed by **DCID** (as used on wire) and UDP 5‑tuple. (See `quiche` README “Connection setup” for accept/connect usage.) ([Docs.rs][2])

### 5.4 Driving connections

* **Ingress**: For each readable UDP datagram:
  `quiche_conn_recv(conn, buf, read, &recv_info)`; process until `ERR_DONE`. Then, if **established** and no H3 yet, create **`h3_conn = quiche_h3_conn_new_with_transport(conn, h3_cfg)`**. ([Docs.rs][10])
* **HTTP/3 poll**: call **`quiche_h3_conn_poll()`** repeatedly until `ERR_DONE`, mapping events to our internal dispatcher:

  * `HEADERS` → build `Request` and route to handler
  * `DATA`    → handler can `req.body.read()` (we call `quiche_h3_recv_body`)
  * `FINISHED`→ finalize route/stream
  * `PRIORITY_UPDATE` → optional app hook
  * `GOAWAY` → graceful shutdown of new requests
  
  Note: H3 DATAGRAMs are not surfaced via `quiche_h3_conn_poll()` in the C FFI. Read QUIC DATAGRAMs via `quiche_conn_dgram_recv()`, and when H3 DATAGRAM is negotiated (peer SETTINGS), parse/emit the H3 flow-id varint to deliver to the registered datagram handler.
* **Egress**: Repeatedly call `quiche_conn_send(out, &send_info)` until `ERR_DONE`; schedule actual `sendto()` honoring pacing `send_info.at`. ([Docs.rs][2])
* **Trailers**: map to `send_additional_headers(is_trailer_section=true)`. (Rust API provides it; C FFI mirrors Rust.) ([QUIC Docs][4])

### 5.7 WebTransport over H3 (experimental)

Note: WebTransport is experimental and compiled in by default. You can disable it with `-Dwith-webtransport=false`. At runtime, set `H3_WEBTRANSPORT=1` to negotiate Extended CONNECT. Optional stream loops can be enabled with `H3_WT_STREAMS=1` and bidirectional binding with `H3_WT_BIDI=1`.

What works now (with `quiche` 0.24.6 C FFI):

- Detect and accept WebTransport sessions using Extended CONNECT:
  - We enable Extended CONNECT whenever WebTransport is built in, and gate runtime behavior on peer support via `quiche_h3_extended_connect_enabled_by_peer()`.
  - On `:method = CONNECT` with `:protocol = webtransport`, route to a WebTransport route and accept the session by replying `:status = 200` on the request stream.
- Session-bound DATAGRAMs:
  - When `quiche_h3_dgram_enabled_by_peer(conn)` is true, encode the H3 DATAGRAM flow-id using the WebTransport Session ID (the CONNECT request stream ID) and send/receive via `quiche_conn_dgram_send/recv`.
  - We surface these to the application through `WebTransportSession.sendDatagram()` and the existing datagram hook, associating payloads with the session.
- Experimental WT streams (implemented in-library):
  - Unidirectional: we parse the WT uni-stream preface `[0x54][session_id]` from peer‑initiated client uni streams (skipping H3 control/QPACK). On success we bind the stream to the session and invoke `on_wt_uni_open` then deliver data via `on_wt_stream_data`/`on_wt_stream_closed`.
  - Bidirectional: when `H3_WT_BIDI=1`, we parse the bidi preface `[0x41][session_id]` on client‑initiated bidi streams and bind similarly. Server can open outgoing uni/bidi via `openWtUniStream/openWtBidiStream` (which write the preface) and send with `sendWtStream`/`sendWtStreamAll`; reads use `readWtStreamAll`.
  - Per‑session limits are enforced via `wt_max_streams_uni` and `wt_max_streams_bidi` in `ServerConfig`. Backpressure is handled with per‑stream pending buffers and write‑quota `wt_write_quota_per_tick`.

Notes and caveats (upstream constraints we work around):

- The `quiche` H3 C FFI does not surface extension stream events; we therefore scan raw QUIC stream iterators to detect incoming WT streams and parse the varint prefaces ourselves. This is an implementation detail that may evolve as upstream APIs grow.
- We do not use capsules; bidi binding is performed via the per‑stream preface, and uni binding via the uni stream type preface.

### 5.5 HTTP/3 features covered (per `quiche`)

* ALPN `h3`, **`with_transport()`** handshake for control/QPACK streams, **`poll()`** event model; **send\_response / send\_body**, **recv\_body**, **send\_additional\_headers** (including **trailers**); **GOAWAY**, **Priority Update**, per-connection **stats**. ([QUIC Docs][1])
* **HTTP/3 DATAGRAM**: use `dgram_enabled_by_peer(conn)` gating; send/receive via QUIC DATAGRAM, and surface as request-associated H3 datagrams when context ID mapping is present. ([QUIC Docs][9])

> **Note on Server Push:** Defined in RFC 9114, but de‑emphasized in practice; Chromium removed support and popular servers stripped it. `quiche::h3::Connection` public methods do not include push APIs in current docs, so we do not expose push in the Zig API. ([IETF Datatracker][14], [Chrome for Developers][5], [QUIC Docs][4])

### 5.6 Security & robustness

* **TLS**: load PEM cert/key via `quiche_config_load_*` functions; enforce SNI and ALPN `h3`. ([Docs.rs][2])
* **Amplification limit** protection: obey `quiche`’s send limits before address validation.
* **Retry**: optional stateless retry using `quiche` helpers (configurable).
* **GREASE & invariants**: optional GREASE to improve interop.
* **QLOG**: enable per-connection qlog file in `qlog_dir` for debugging/analysis (leveraging `quiche` qlog support exposed via config).
* **Header validation**: every request header set is checked against configurable limits (`max_header_count`, `max_header_name_length`, `max_header_value_length`). Names must match RFC 7230 token rules (pseudo-headers allowed), values reject control characters/CRLF injection. Failures yield 400/431 with structured logging.
* **Body bounds**: non-streaming handlers respect `max_non_streaming_body_bytes` (override via `H3_MAX_BODY_MB`); exceeding the cap returns 413 via the centralized `errorToStatus` map.
* **Concurrency caps**: per-connection request and download limits (`max_active_requests_per_conn`, `max_active_downloads_per_conn`) prevent runaway resource usage; when hit, we log a WARN line and emit 503.
* **Centralized logging**: compile-time log filtering via `-Dlog-level=[error|warn|info|debug|trace]`, plus runtime overrides `H3_LOG_LEVEL` / `H3_DEBUG=1`. Logging helpers (`server_logging.{errorf, warnf, infof, debugf, tracef}`) route everything through one module with throttled quiche debug callbacks.

---

## 6) Configuration → `quiche` mapping

We feed the transport-related fields from `ServerConfig` (idle timeout, stream/data caps, congestion control string, disable-active-migration, pacing, datagram toggles, UDP payload sizing, GREASE, retry) directly into the corresponding `quiche::Config` mutators. ([Docs.rs][2])

HTTP/3 specific fields (`alpn_protocols`, header/body limits, extended CONNECT/WebTransport flags) log through `quiche::h3::Config` using:

* `set_application_protos()` with the configured ALPN list (default `h3`, `hq-*`, `http/0.9`)
* `enable_extended_connect(true)` when WebTransport is built in (default) or when we need CONNECT-UDP
* `enable_datagrams()` when both `enable_dgram` and the H3 DATAGRAM context are requested
* QPACK table/blocked stream caps set to sensible defaults (currently zero — match quiche examples)

At startup we call:

```text
quiche_config_new(PROTOCOL_VERSION)
quiche_config_set_application_protos(h3::APPLICATION_PROTOCOL) // i.e., "h3"
h3_config = quiche_h3_config_new()
quiche_h3_conn_new_with_transport(conn, h3_config)
```

(Matching the Rust docs for ALPN + `with_transport()`.) ([QUIC Docs][9])

---

## 7) Error handling & backpressure

* Any `StreamBlocked` / `Done` from `send_*` calls causes us to **re-arm writability** for that stream and retry once transport capacity is available (this mirrors `quiche` docs guidance). ([QUIC Docs][4])
* `FrameUnexpected` or other H3 protocol errors: `quiche` **closes** with appropriate code; we surface an error and teardown the route cleanly. ([QUIC Docs][16])
* On QUIC close (`conn_is_closed`), we free state, invoke on-close hooks, and drop pending routes.

---

## 8) Observability & stats

* `Server.exportMetrics()` aggregates:

  * `quiche_conn_stats()` and `path_stats` (bytes sent/recv, lost, RTT, PTO, **dgram\_sent/recv** counters, etc.). ([Docs.rs][17])
  * H3 per-connection stats via `h3_conn.stats()` where available. ([QUIC Docs][4])
* Optional **qlog** per-connection in `qlog_dir` for performance debugging.

---

## 9) Testing strategy

### 9.1 Unit tests (Zig)

* **FFI wrappers**: creation/freeing of `quiche_config`, `h3_config`, error code translation, header conversion (Zig <-> `quiche_h3_header`), datagram send/recv glue.
* **Router**: method/path matching, param extraction, wildcard globs.
* **Body streaming**: backpressure and partial writes returning `Done`, trailers flow (`send_additional_headers(...is_trailer_section=true)` in the final phase). ([QUIC Docs][4])
* **Timer wheel**: expiration, re-scheduling from `timeout()` durations (nanos), ensuring `on_timeout()` leads to new send opportunities. ([Docs.rs][2])

### 9.2 Integration tests

* **Loopback single-connection E2E**

  * Start our Zig server on ephemeral port with self-signed cert.
  * Use `quiche` **C client example** (`http3-client.c`) or **`quiche-client` app** to fetch endpoints, verify headers/body/trailers. ([Docs.rs][10])
  * Verify H3 events: headers/data/finished sequence, correct status codes, content length.
* **Concurrent requests** (e.g., 100 GETs over 1 connection, and 100 over 20 connections).
* **Large body streaming**: upload/download 1–4 GiB with bounded buffer, check checksums, ensure no leaks.
* **Trailers**: server emits trailers; client verifies they arrive after final data. (Use Rust client or C client reading via `quiche_h3_recv_body` and header callbacks.) ([Docs.rs][10])
* **Priorities**: server sends `PRIORITY_UPDATE` or responds to one; verify with client (where supported). ([QUIC Docs][4])
* **DATAGRAM**: if peer enables H3 DATAGRAM (`dgram_enabled_by_peer()`), test echo and loss tolerance; also test pure QUIC DATAGRAM path without H3 association. ([QUIC Docs][9])
* **WebTransport (experimental)**:
  * Extended CONNECT handshake: send `CONNECT` with `:protocol = webtransport`, verify `200` acceptance when enabled and peer supports it.
  * WT DATAGRAM echo bound to session ID (flow-id); verify delivery and association with the correct session.
* **GOAWAY**: server sends GOAWAY (graceful); client observes and new requests get rejected. ([QUIC Docs][4])
* **Retry & token**: enable stateless retry; clients must present valid token.

### 9.3 Interop & conformance

* **QUIC Interop Runner**: build a Docker image for our server matching the runner’s interface; run the full matrix against popular clients/servers. (There’s precedent in `cloudflare/quiche-qns` images.) ([GitHub][3], [Docs.rs][2])
* **`h3i` tool**: use Cloudflare’s recently open-sourced **h3i** to send intentionally malformed or edge-case H3 sequences to validate our server’s correctness and error paths. ([The Cloudflare Blog][18], [Fossies][19])

### 9.4 Negative/fault injection

* **Packet loss/dup/reorder** using `tc netem` scenarios (e.g., 1–5% loss, 50–150ms RTT) to ensure stability and no panics while maintaining throughput.
* **Slowloris-style** slow request bodies over H3 to exercise flow control & backpressure.

---

## 10) Benchmarking plan

### 10.1 Throughput & latency

* **Single connection throughput**: send large response bodies (1–8 GiB) and measure goodput vs. `quiche-server` (apps) on the same host/kernel. (The README shows how to run `quiche-server`.) ([Docs.rs][2])
* **Concurrency scaling**: N clients × M streams each; record aggregate throughput, CPU%, memory, p50/p99 response latency.

### 10.2 Adverse networks

* Use `tc netem` profiles:

  * 50ms RTT + 1% loss,
  * 150ms RTT + 0.2% loss,
  * Jitter 5–20ms,
  * Reordering 1–5%.
* Compare **streams vs. DATAGRAM** for telemetry-style payloads where reliability is optional.

### 10.3 Instrumentation

* Export qlog and `quiche` **Stats/PathStats** counters, and maintain Zig-level DATAGRAM counters. Note: the C FFI `quiche_stats`/`quiche_path_stats` do not currently include `dgram_sent/recv` fields (these exist in Rust), so we track DATAGRAM counts in Zig.

---

## 11) Detailed test matrix (enumerated)

1. **Config**
   1.1 Invalid cert/key path → server init fails gracefully.
   1.2 ALPN mismatch (client sends `h2`) → handshake fails.
   1.3 `enable_datagrams=false` → datagram API returns “not enabled”.

2. **Handshake & Control**
   2.1 Normal handshake → `h3::Connection::with_transport()` succeeds after `is_established()`. ([QUIC Docs][1])
   2.2 Retry on first flight → client proceeds with token.

3. **Routing**
   3.1 Exact match `/hello` and wildcard `/files/*`.
   3.2 Parameterized `/user/:id`.

4. **Headers & QPACK**
   4.1 Large header sets (≥8KB) within configured limits.
   4.2 QPACK table tuning (different `qpack_max_table_capacity`). ([QUIC Docs][15])

5. **Bodies**
   5.1 Streaming request body upload (chunked) → save to /dev/null.
   5.2 Streaming response body with backpressure and `Done` retries. ([QUIC Docs][4])
   5.3 **Trailers** after body (server sends via `send_additional_headers(...is_trailer_section=true)`). ([QUIC Docs][4])

6. **Priority**
   6.1 Server sends `PRIORITY_UPDATE` → client sees it.
   6.2 Client sends priority change → server’s `PriorityUpdate` event appears and `take_last_priority_update()` returns the field value. ([QUIC Docs][4])

7. **GOAWAY**
   7.1 Server GOAWAY: in-flight complete, new requests rejected. ([QUIC Docs][4])

8. **DATAGRAM**
   8.1 QUIC DATAGRAM disabled: send returns error.
   8.2 Enabled: echo and measure loss tolerance.
   8.3 H3 DATAGRAM with context ID: request-bound datagrams observed once peer SETTINGS processed (`dgram_enabled_by_peer()`). ([QUIC Docs][9])

9. **Timeouts & Loss**
   9.1 Idle timeout closes connections per config.
   9.2 Loss injection (1–5%) → app remains stable; throughput degrades gracefully.

10. **Close**
    10.1 Graceful close (`conn_close`) with an error code; handlers finalize cleanly.

11. **Interop**
    11.1 Run QUIC Interop Runner basic suite against major peers (quic-go, msquic, ngtcp2/nghttp3, Quinn). Track green/red matrix. ([GitHub][3])
    11.2 `h3i` invalid sequences produce correct HTTP/3 errors and closes. ([The Cloudflare Blog][18])

---

## 12) Performance targets (initial)

* **Single core Linux, loopback:**

  * > 8 Gbps goodput for large sequential body (MTU \~1350; GSO helps if enabled).
  * p99 response latency < 1 ms for small responses under 500 concurrent streams.
* **DATAGRAM echo** under 1% loss: loss observed equals netem loss ±0.2%; no reorder crashes.

(Performance will vary with kernel offloads and NIC. Use qlog to analyze pacing and cwnd.)

---

## 13) Implementation notes & gotchas

* **ALPN**: set to `h3` via `set_application_protos(h3::APPLICATION_PROTOCOL)`. (Rust docs show this exact call; C FFI mirrors it.) ([QUIC Docs][9])
* **Creating H3**: only call `quiche_h3_conn_new_with_transport()` once QUIC is established. (Matches examples.) ([Docs.rs][10])
* **Edge-triggered semantics**: `h3_conn.poll()` events are **edge-triggered**; do not assume level-triggering. Re-arm reads after consuming all data until `Done`. ([QUIC Docs][4])
* **Pacing**: honor `SendInfo.at`; consider `SO_TXTIME` for Linux. ([Docs.rs][2])
* **H3 push**: not supported in this API for reasons above. ([Chrome for Developers][5])
* **Zig 0.15.1 I/O**: prefer POSIX syscalls and custom thin wrappers; std I/O APIs are actively evolving. ([Zig Programming Language][7])

---

## 14) Deliverables

1. `zig-quiche-h3` library with:

   * Public API (as above), full docs & examples.
   * POSIX backends (epoll/kqueue) with timer integration and pacing.
   * Event backend abstraction (`EventLoop`), defaulting to libev; optional raw epoll/kqueue.
   * FFI wrappers to `quiche.h`, with rigorous lifetimes.
   * Router, Request/Response streamers, trailers, priority, GOAWAY.
   * QUIC + H3 DATAGRAM integration.
   * WebTransport over H3 (experimental): session accept + DATAGRAMs.
   * Metrics & qlog hooks.

2. **Tests**:

   * `zig test` suite (unit).
   * `integration/` harness spawning server + `quiche-client` binaries.
   * Dockerfiles for **Interop Runner**, plus CI workflow that can run a subset locally.

3. **Benches**:

   * Throughput benchmark for large responses (single and many connections).
   * DATAGRAM echo microbench.
   * Netem scripts to reproduce loss/latency conditions.

---

## 15) Key references (for implementers)

* **quiche README & usage (C & Rust)**: how to build, how the API is driven (`accept`, `recv`, `send`, timers, pacing); C FFI details (`--features ffi`, `libquiche.a`). ([Docs.rs][2])
* **quiche::h3 module**: ALPN (`APPLICATION_PROTOCOL`), connection setup (`with_transport`), event model, and server flow with **`poll()`**, `send_response`, `send_body`, **`send_additional_headers`** (trailers), priority update, GOAWAY. ([QUIC Docs][1])
* **C examples (`http3-client.c`)**: `quiche_h3_conn_new_with_transport`, `quiche_h3_conn_poll`, event switch (HEADERS, DATA, FINISHED, RESET, GOAWAY), `quiche_h3_send_request`, `quiche_h3_recv_body`. ([Docs.rs][10])
* **Datagrams**: Rust API check for `h3` datagram support `dgram_enabled_by_peer()`; QUIC DATAGRAM counters exist in Rust `Stats`, but are not exposed via the C FFI `quiche_stats`. Track DATAGRAM counts in Zig. ([QUIC Docs][9], [Docs.rs][17])
* **Interop & tools**:

  * QUIC Interop Runner (automated interop matrix). ([GitHub][3])
  * Cloudflare **h3i** low-level H3 tester (great for negative tests). ([The Cloudflare Blog][18])
* **Zig 0.15.1**: I/O changes (reason we lean on POSIX directly). ([Zig Programming Language][7])

---

## 16) Roadmap (post‑MVP)

* Windows (IOCP) backend; optional io\_uring on Linux.
* WebTransport streams (bi/uni): add full WT stream support once `quiche` exposes extension stream events in H3 C FFI, or we adopt a patched upstream.
* Advanced load balancing (QUIC-LB connection ID encoding). ([QUIC][20])
* Admin endpoints for live stats, qlog toggle, and connection draining.

---

## 17) Host FFI (Bun) — Thin C ABI

Goal: expose a minimal, stable C ABI so Bun apps can `dlopen()` a shared library and drive the server via `bun:ffi`. We keep the surface narrow and C‑friendly and map 1:1 to the public Zig API concepts.

Build target

- Produce a shared library (`.so`/`.dylib`) named `libzigquicheh3` exporting the symbols below.
- Keep ABI C‐only; no Zig types in the ABI boundary. Internally, this library links `libquiche.a` and libev.

Call conventions

- All exported functions use the C ABI.
- Long‑running work (server loop) runs on a dedicated thread inside the library. JS callbacks must be created as Bun `JSCallback` and marked thread‑safe, or use the polling mode below.

Core types

```c
typedef struct zig_h3_server zig_h3_server;     // Opaque server handle
typedef struct zig_h3_response zig_h3_response; // Opaque response handle

typedef struct {
  const char* name;  // UTF‑8, null‑terminated
  const char* value; // UTF‑8, null‑terminated
} zig_h3_header;

typedef struct {
  const char* method;     // e.g. "GET"
  const char* path;       // e.g. "/hello"
  const char* authority;  // host
  const zig_h3_header* headers;
  size_t headers_len;
  uint64_t conn_id;
  uint64_t stream_id;     // request stream id
} zig_h3_request;

typedef void (*zig_h3_request_cb)(void* user, const zig_h3_request* req, zig_h3_response* resp);
typedef void (*zig_h3_dgram_cb)(void* user, uint64_t context_id, const uint8_t* data, size_t len, uint64_t req_stream_id);
typedef void (*zig_h3_log_cb)(void* user, const char* line);
```

Exported functions (subset)

```c
// Library info
const char* zig_h3_version(void); // returns static string

// Server lifecycle
zig_h3_server* zig_h3_server_new(/* config JSON or fields */);
int zig_h3_server_free(zig_h3_server*);

// Logging hook (optional)
void zig_h3_set_log(zig_h3_server*, zig_h3_log_cb cb, void* user);

// Routing
int zig_h3_route(zig_h3_server*, const char* method, const char* pattern,
                 zig_h3_request_cb cb, void* user);

// Datagram endpoint
int zig_h3_datagram(zig_h3_server*, const char* pattern,
                    zig_h3_dgram_cb cb, void* user);

// Start/stop (runs libev loop in background thread)
int zig_h3_start(zig_h3_server*);
int zig_h3_stop(zig_h3_server*);

// Response writer
int zig_h3_resp_send_head(zig_h3_response*, uint16_t status,
                          const zig_h3_header* headers, size_t headers_len,
                          bool has_body);
ssize_t zig_h3_resp_send_body(zig_h3_response*, const uint8_t* data,
                              size_t len, bool fin);
int zig_h3_resp_send_trailers(zig_h3_response*, const zig_h3_header* headers,
                              size_t headers_len);

// QUIC/H3 DATAGRAM send (connection‑scoped)
ssize_t zig_h3_dgram_send(zig_h3_server*, uint64_t conn_id,
                          uint64_t context_id, const uint8_t* data, size_t len);

// WebTransport (experimental) — session = CONNECT stream id
typedef void (*zig_wt_session_cb)(void* user, uint64_t session_id, const zig_h3_request* req);
int zig_h3_webtransport(zig_h3_server*, const char* pattern,
                        zig_wt_session_cb cb, void* user);
ssize_t zig_wt_send_datagram(zig_h3_server*, uint64_t session_id,
                             const uint8_t* data, size_t len);
int zig_wt_close(zig_h3_server*, uint64_t session_id, uint64_t code, const char* reason);
```

JS usage model (bun:ffi)

- Load the shared lib with `dlopen()` and declare symbols with `args`/`returns` using Bun’s `FFIType`/string labels.
- Register JS handlers by wrapping them as `new JSCallback({ callback, args: [...], returns: "void", threadsafe: true })` and pass `.ptr` as `FFIType.ptr`.
- For C‑>JS calls from a non‑JS thread, only use thread‑safe callbacks; otherwise prefer polling mode.

Polling mode (no callbacks)

- Alternative to callbacks: export `zig_h3_next_event()` that returns a compact event struct (request_started, body, finished, datagram, goaway…). JS polls and calls response APIs. This avoids cross‑thread JS calls at the expense of more roundtrips.

FFI type mapping (Bun)

- Prefer simple scalars (`i32`, `u64`, `bool`) and pointers (`ptr`, `cstring`). For strings, use `cstring` and document ownership: inputs are read‑only; outputs are either static or must be freed via an explicit `zig_h3_free_cstring(char*)`.
- For callbacks, the C side only stores the raw function pointer and a `void* user` cookie. JS must keep the `JSCallback` alive for the duration (call `.close()` on shutdown).

Gotchas

- Threading: Bun’s `JSCallback` must be created with `threadsafe: true` if called from the server thread; otherwise, use polling mode.
- Lifetime: ensure `response` handles are valid only during the handler’s lifetime or until FIN.
- ABI stability: keep symbol names versioned or provide `zig_h3_version()` for feature checks.

### Closing note

This spec **keeps your application surface simple**—configure server parameters, declare endpoints, optionally hook datagrams—while leveraging `quiche`’s **documented** model for QUIC + HTTP/3 (recv/send, timers, `h3::Connection::with_transport`, `poll`, `send_response`, `send_body`, trailers, GOAWAY, priority). It also **bakes in testability**: you can exercise correctness and performance with `quiche`’s own tools and the Interop Runner from day one. ([Docs.rs][2], [QUIC Docs][1], [GitHub][3])

If you want, I can add a first-pass `build.zig` and the FFI bindings skeleton next.

[1]: https://docs.quic.tech/src/quiche/h3/mod.rs.html "mod.rs - source"
[2]: https://docs.rs/crate/quiche/latest/source/README.md "quiche 0.24.6 - Docs.rs"
[3]: https://github.com/quic-interop/quic-interop-runner "QUIC interop runner"
[4]: https://docs.quic.tech/quiche/h3/struct.Connection.html "Connection in quiche::h3 - Rust"
[5]: https://developer.chrome.com/blog/removing-push "Remove HTTP/2 Server Push from Chrome | Blog"
[6]: https://mailman.nginx.org/pipermail/nginx-devel/2023-May/RMGWK746UHXKMNFBO3JYNU4SRA5HRSIR.html "[PATCH 3 of 4] HTTP/3: removed server push support"
[7]: https://ziglang.org/download/0.15.1/release-notes.html "0.15.1 Release Notes"
[8]: https://github.com/cloudflare/quiche "cloudflare/quiche: 🥧 Savoury implementation of the QUIC ..."
[9]: https://docs.quic.tech/src/quiche/h3/mod.rs.html "quiche/h3/ mod.rs"
[10]: https://docs.rs/crate/quiche/latest/source/examples/http3-client.c "quiche 0.24.4"
[11]: https://android.googlesource.com/platform/external/rust/crates/quiche/%2B/refs/tags/android-security-12.0.0_r53/examples/http3-client.c "examples/http3-client.c - platform/external/rust/crates/quiche"
[12]: https://docs.rs/crate/quiche/latest/source/include/quiche.h "quiche 0.24.6 - Docs.rs"
[13]: https://gitlab.informatik.hu-berlin.de/thimmaka/quiche/-/blob/e98cccd9256be546578bcb6ac42881e2a06a25f7/examples/http3-server.c "quiche - examples - http3-server.c"
[14]: https://datatracker.ietf.org/doc/html/rfc9114 "RFC 9114 - HTTP/3"
[15]: https://docs.quic.tech/quiche/h3/struct.Config.html "Config in quiche::h3 - Rust"
[16]: https://docs.quic.tech/quiche/h3/enum.Error.html "Error in quiche::h3 - Rust"
[17]: https://docs.rs/quiche/latest/quiche/struct.Stats.html "Stats in quiche - Rust"
[18]: https://blog.cloudflare.com/open-sourcing-h3i "Open sourcing h3i: a command line tool and library for low- ..."
[19]: https://fossies.org/linux/quiche/h3i/README.md "quiche: h3i/README.md"
[20]: https://quicwg.org/load-balancers/draft-ietf-quic-load-balancers.html "QUIC-LB: Generating Routable QUIC Connection IDs"
