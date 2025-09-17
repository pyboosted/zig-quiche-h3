# HTTP/3 Client Development Plan for `zig-quiche-h3`

## Current Library Status & Issues

`zig-quiche-h3` today ships a feature-rich HTTP/3 **server** on top of Cloudflare’s `quiche` C FFI. The QUIC layer handles handshake, pacing, qlogs, and per-connection bookkeeping; the HTTP stack exposes request/response surfaces split across `src/http/response/{core,body,streaming_ext,datagram}.zig` with a comptime status table; and the routing story was recently converged so both compile-time and dynamic registration share `src/routing/matcher_core.zig`. We also track per-connection request/download counters and keep a reusable DATAGRAM buffer to minimise allocator churn. WebTransport support (sessions, datagrams, outgoing uni/bidi streams) is compiled in behind `-Dwith-webtransport` and gated at runtime by `H3_WEBTRANSPORT=1`.

Before outlining the client, it’s worth highlighting the remaining **server-side gaps** that may influence client work:

- **Connection timeout loop:** the periodic `onTimeoutTimer` wiring exists but still points at a `TODO` `checkTimeouts` implementation. Idle connections currently rely on quiche’s per-connection timers being polled elsewhere; we’ll need to either wire that hook up or ensure the client doesn’t assume server-driven idle pruning.
- **WebTransport limitations:** because `quiche`’s H3 C API still ignores peer-initiated WebTransport streams, the server only supports DATAGRAMs and server-initiated uni/bidi streams. The client will face the same upstream limitation (we can originate streams but not receive peer-opened WT streams until the FFI grows support).
- **Platform scope:** the project targets POSIX (Linux/macOS/\*BSD) only. Windows support remains out of scope; the client should adopt the same constraint.
- **Planned roadmap dependency:** Milestone 9 in the roadmap is exactly “full HTTP/3/WebTransport client harness.” Interop/perf tuning and Bun FFI milestones are now explicitly blocked on this work, so the spec needs to set the foundation for those follow-ups.

With those caveats in mind, the server is stable enough for a complementary HTTP/3 **client**. The rest of this document proposes that client in detail.

## HTTP/3 Client Goals & Scope

## Server Prerequisite

Before implementation we must finish the server-side timeout loop (`onTimeoutTimer` / `updateTimer` in `src/quic/server/mod.zig`). Once that lands (tracked separately), the client can rely on timely idle cleanup and retransmit wakeups.

**Goal:** Develop a `zig-quiche-h3` HTTP/3 **client** (in the same repository) using Cloudflare’s `quiche` library, analogous to the current server implementation. The client should be capable of performing **HTTP/3 requests over QUIC** and supporting all major HTTP/3 features. Specifically, the client will support:

- **Standard Request/Response over HTTP/3:** The client can initiate HTTP/3 connections to a server, send GET/POST requests with headers (and optional body), and receive responses (headers, body, trailers). This includes proper handling of multiple concurrent streams (HTTP/3 allows multiplexing many requests).
- **Bidirectional Streams:** Ability to send request bodies (for POST/PUT) and receive streaming responses. The client should handle partial data (flow-controlled reads/writes) and indicate end-of-stream (FIN) properly, similar to how the server handles streaming bodies.
- **QUIC Datagram Extension:** Support sending and receiving QUIC DATAGRAM frames (unencrypted payloads over QUIC). If the QUIC transport and peer allow datagrams, the client API should allow sending arbitrary datagrams and provide received datagrams to the application. This is useful for protocols built on QUIC that use datagrams.
- **HTTP/3 DATAGRAMs:** If the HTTP/3 Datagrams draft is in use (negotiated via the H3 DATAGRAM setting), support them on the client. This means associating datagrams with HTTP requests (using the `Flow ID` mapping as done on server side) so that, for example, a client could send or receive datagrams tied to a particular request or WebTransport session. The client should check if the peer (server) has enabled H3 datagram support and expose an API to send datagrams in the context of a request.
- **WebTransport Sessions:** Provide **experimental** WebTransport support on the client side, analogous to the server. The client should be able to initiate a WebTransport session via an Extended CONNECT request, handle the session negotiation (if the server supports it), and then allow sending/receiving DATAGRAMs on that session. Full stream support within WebTransport will be limited by the same upstream issues (no automatic surfacing of server-initiated WT streams). Initially, the client will at least support opening a session and exchanging datagram messages (and possibly client-initiated unidirectional streams if needed as test data, noting that server-initiated streams won’t be delivered by `quiche` yet).
- **Graceful Connection Management:** Handle HTTP/3 control frames like GOAWAY. For example, if the server sends GOAWAY, the client should stop sending new requests and close when appropriate. The client should also be able to close the connection cleanly on its own (sending a H3 connection close or a QUIC close).
- **Performance & Multiplexing:** The client should allow many requests in parallel (high concurrency) over one connection and also support opening multiple connections if needed. For instance, we should be able to perform dozens of simultaneous GET requests on one HTTP/3 connection (to test prioritization and concurrency), as well as handle multiple separate connections (though initially one connection per client instance is fine).
- **Interop and Compliance:** The client should conform to HTTP/3 and QUIC standards as enforced by quiche. It should be tested against known servers (e.g. the quiche example server, ngtcp2 server, or our own server) to ensure it properly negotiates TLS, ALPN `h3`, and transfers data correctly without protocol violations. Features like header compression (QPACK), priority updates, etc., are largely handled internally by quiche, but the client should expose anything needed to use them if applicable (for example, the client might expose a way to send PRIORITY_UPDATE frames if quiche’s API allows the client side to do so).

**Non-Goals / Out of Scope (for now):**

- **HTTP/3 Server Push:** No need to implement client-side push handling, since server push is not supported by our server and generally deprecated in H3 (Chrome and others dropped push).
- **MASQUE/Proxying:** Not in scope. The client will focus on direct HTTP requests, not acting as a proxy or using MASQUE tunneling at this stage.
- **Windows Support:** As noted, initial implementation will target Linux and macOS. Windows support can be revisited later once the core client is stable (similar to the server’s phase1 scope).
- **TLS Certificate Verification Edge-Cases:** The client will use `quiche` default behaviors for TLS. We will allow disabling peer verification for local testing (like quiche’s client example does with a flag), but a fully fleshed-out certificate validation or custom verify callback is not a priority in this internal project.

## Proposed Client Architecture

### Module layout

### FFI requirements

- Extend `src/ffi/quiche.zig` with client wrappers: `quiche_connect`, `quiche_conn_is_established`, `quiche_conn_peer_verified`, TLS verify toggles, and utility accessors for handshake state.
- Reuse existing send/recv helpers; document which server wrappers are reused vs new ones.
- Expose helpers to set optional qlog paths, idle timeout queries (`timeoutAsMillis`), and datagram APIs for the client.

- `src/client/`
  - `config.zig` – defines `ClientConfig` (authority, ALPN list, TLS verification, concurrency/timeout knobs).
  - `mod.zig` – high-level API orchestrating QUIC and H3 layers.
  - `request.zig` / `response.zig` – helpers for outgoing requests and streaming responses.
  - `webtransport.zig` – optional helpers for client-initiated WebTransport sessions/streams.
- `src/quic/client.zig` – handles socket setup, `quiche_conn_new_with_tls`, packet I/O, timeouts, qlog, and QUIC datagrams, integrating with `src/net/event_loop.zig`.
- `src/h3/client.zig` – wraps `quiche_h3_conn_new_with_transport`, manages stream IDs, header encoding, body/trailer streaming, GOAWAY handling.
- Shared helpers (`src/ffi/quiche.zig`, `src/h3/datagram.zig`, `src/http/status_strings.zig`, `src/errors.zig`) remain; shared logic (e.g. DATAGRAM flow-id encoding) should be factored into reusable utilities.

### Public API sketch

```zig
pub const Client = struct {
    pub fn init(allocator: std.mem.Allocator, cfg: ClientConfig) !*Client;
    pub fn deinit(self: *Client) void;

    pub fn connect(self: *Client, target: ServerEndpoint) !void;
    pub fn send(self: *Client, req: HttpRequest) !ResponseHandle;

    pub fn poll(self: *Client) !void; // single event-loop iteration
    pub fn run(self: *Client) !void;  // drive until outstanding work completes

    pub fn sendQuicDatagram(self: *Client, payload: []const u8) !void;
    pub fn sendH3Datagram(self: *Client, stream_id: u64, payload: []const u8) !void;

    pub fn openWebTransport(self: *Client, req: HttpRequest) !WtSessionHandle;
};
```

- `ClientConfig` mirrors server transport knobs (idle timeout, max data/streams, datagram enable) and adds TLS verification settings (verify on/off, optional custom CA bundle), DNS resolution strategy (initially synchronous `getaddrinfo`, happy-eyeballs queued for later), logging/qlog toggles, and optional metrics hooks.
- `ServerEndpoint` holds scheme/authority/port to allow multi-origin usage.
- `HttpRequest` carries method, scheme, authority, path, headers, optional streaming body provider.
- `ResponseHandle` exposes async consumption (`awaitHeaders`, `readBodyChunk`, `trailers`, `status`, completion callback) and can back a blocking `fetch()` helper.
- `poll()` is non-blocking and processes pending events once; `run()` blocks until outstanding requests complete; `fetch()` wraps `send` + `run()` for convenience when only one request is needed.
- `WtSessionHandle` lets callers send WT datagrams, open client-initiated uni/bidi streams, and close sessions.

### CLI tooling

- Provide `zig build h3-client` binary powered by `src/args.zig`.
- Support flags: `--url`, `--method`, `--header`, `--data`, `--body-file`, `--save-body`, `--send-dgram`, `--open-wt`, `--wt-send-dgram`, `--max-streams`, `--with-webtransport`, etc.
- Emit structured output (JSON or key/value lines) for Bun E2E tests and benchmarking harnesses.
- Allow scripted multi-request scenarios (config files) to exercise concurrency, streaming, datagram, and WebTransport flows.

### Event loop integration

- Reuse `src/net/event_loop.zig` to register UDP readability watchers and per-connection timers (`quiche_conn_timeout_as_nanos`). Client and server may share the same loop when embedded in one process; tests can also spin separate loops/threads if simpler.
- Expose both `run()` (self-contained loop for CLI) and `poll()` (single iteration for embedding/Bun FFI/tests).
- Ensure multiple client instances can coexist within one loop to power high-concurrency benchmarks (Milestone 10) and to run alongside the server during integration tests.

### Internal flow

1. `connect` resolves/builds the remote address, opens a non-blocking UDP socket, configures quiche (SNI, ALPN list, transport caps), and drives handshake until `quiche_conn_is_established`.
2. `send` allocates a new stream, serializes headers via `quiche_h3_send_request`, and schedules body writes (streaming via chunk generator for large uploads).
3. Event loop callback drains packets (`quiche_conn_recv`), polls H3 events (`quiche_h3_conn_poll`), and routes them to per-stream state machines resolving `ResponseHandle`s.
4. QUIC/H3 DATAGRAMs reuse shared helpers for flow-id encoding and dispatch payloads to user callbacks or WebTransport sessions.
5. WebTransport sessions maintain per-session state (write quotas, pending buffers) mirroring server logic from the client perspective.

### Error handling & observability

- Reuse `src/errors.zig`, adding client-specific errors (`error.TlsVerify`, `error.GoAway`, `error.StreamReset`, `error.DatagramUnsupported`).
- Extract shared logging helpers so both client and server benefit from throttled structured logging.
- Offer optional qlog output and basic metrics (bytes sent/recv, RTT, active streams/datagrams) to feed Milestone 10 benchmarking.

### Extensibility

- Architect for future connection pooling (authority → connection map) and 0-RTT when upstream APIs allow.
- Keep the API compatible with Bun FFI bindings (Milestone 11) by avoiding hidden globals and clarifying threading expectations.
- Leave hooks for PRIORITY_UPDATE, MASQUE, or other extensions without major refactors.

## Implementation Plan (Milestones)

We propose an incremental implementation in stages, verifying each step with tests:

1.  **Milestone C1: QUIC Client Handshake** – *Establish the basic QUIC connection.*  
    *Implementation:* Create `QuicClient.init` and `connect()`. Generate a source connection ID (random 16 bytes like the server helper), configure quiche for client mode (ALPN `h3`, SNI derived from target, TLS verify flag/custom CA), and call `quiche_connect(...)` to create the `quiche_conn`. Resolve the remote hostname via `std.net.Address.resolveIp`/`getaddrinfo` (IPv6 first, fall back to IPv4) and bind a non-blocking UDP socket on an ephemeral port (mirroring server socket options). Register the socket with the `EventLoop` for readability. Implement the packet processing loop: read incoming packets via `quiche_conn_recv`, flush pending packets with `quiche_conn_send`, and track the next timeout via `quiche_conn_timeout_as_millis()` so the loop can call `quiche_conn_on_timeout()` when idle. Manage initial handshake completion with `quiche_conn_is_established()` and expose qlog setup analogous to the server.  
    *Test/Verification:* Use a known HTTP/3 server (e.g. our Zig server or quiche’s example server) and attempt a connection. Without sending H3 requests yet, verify the QUIC handshake completes (e.g., `quiche_conn_is_established` becomes true) and no errors occur. Also confirm that a qlog can be generated for the client if enabled (the client should call `quiche_conn_set_qlog_path` similar to server for debugging).

2.  **Milestone C2: Basic HTTP/3 GET Request/Response** – *Send one simple request and get response.*  
    *Implementation:* Initialize an H3 connection after handshake: call `quiche_h3_config_new` and `quiche_h3_conn_new_with_transport(conn)`. Implement `sendRequest` to allocate the next client stream ID (bidi streams start at 0 and increment by 4; uni streams start at 2), assemble headers (`:method`, `:scheme`, `:authority`, `:path`, etc.), and call `quiche_h3_send_request` (which takes care of QPACK encoding). For streaming uploads, queue body chunks using quiche’s streaming APIs and track flow-control backpressure. In the event loop, poll for H3 events via `quiche_h3_conn_poll` after each `conn_recv`. Handle HEADERS, DATA, FIN events, and write the results into the `ResponseHandle`. Once Finished, resolve the response callback/promise.  
    *Test:* Start the Zig QUIC server (which has a default route returning “Hello, HTTP/3!” or similar). Use the new client to GET “/” from it. Verify that the response status (e.g. 200) and body match expectations. This can be done in a simple unit test or manual run. Also test against quiche’s own HTTP/3 server (e.g. `cargo run -p quiche_apps --bin http3-server` from the submodule) to verify interoperability: the client should be able to fetch a known URL from that server as well. At this stage, we have one request at a time working.

3.  **Milestone C3: Concurrent Streams & Multiple Requests** – *Support parallel requests on a single connection.*  
    *Implementation:* Remove the limitation of one-at-a-time requests. Ensure that `sendRequest` can be called multiple times (before earlier responses complete), which means multiple stream IDs active. Our event loop handling needs to iterate over events for *all* streams: `quiche_h3_conn_poll` will yield events possibly in order of arrival. We must handle each event, and continue polling until `H3_DONE` (no more events) is returned. Manage the `stream_states` map so that each stream’s incoming data is routed to the correct Response object or callback. Also implement flow control: if `quiche_h3_recv_body` returns `Done` (meaning no data available or stream blocked), break out and continue later when more data arrives (our event loop will trigger again on socket readability). Similarly, be prepared for `StreamBlocked` errors on sending data – quiche might signal that it couldn’t send all request data; we should retry when writable (server code handles analogous backpressure for responses).  
    We should also consider opening multiple QUIC connections (e.g., to different servers or for load balancing). Likely, the initial version will manage one connection per `QuicClient` instance. If needed, the user can instantiate multiple clients. We do not need a connection pool in this scope.  
    *Test:* Simulate 10 or 20 concurrent GET requests to our server (for example, fetch `/api/users/1` for ids 1–20 in parallel). The server already supports concurrent streams and will respond with JSON. Verify all responses are received correctly. Also test interleaved sends: e.g., send two requests back-to-back without waiting, ensure both complete. We can also use a public HTTP/3 endpoint (if available) to test concurrency (or run two clients against one server to test multi-connection scenario).

4.  **Milestone C4: Sending Request Body & Streaming Responses** – *Handle POST requests and large payloads efficiently.*  
    *Implementation:* Extend `sendRequest` to accept an optional request body (e.g. for POST). For small bodies, we can pass them directly in `quiche_h3_send_request` if supported (quiche C API allows sending some body bytes with the headers and a FIN flag). For large bodies or streaming upload, implement a loop to send the body in chunks via `quiche_h3_send_body` (or by keeping the stream open and using `quiche_conn_stream_send` if needed). Respect flow control: if quiche returns `STREAM_BLOCKED`, wait for a writable event. The client should expose a way for the user to stream data (e.g., a callback that provides data chunks when the stream is writable, or a `uploadFile()` helper that reads a file in chunks). This is analogous to the server’s `Response.writeAll()` and streaming support, but on the client side.  
    Also, handle large *responses* without buffering everything in memory. We can invoke a user’s `onBodyChunk` callback as data arrives, or provide an interface to iterate over response body bytes. If the user doesn’t supply a streaming callback, we might accumulate the body up to a certain size then switch to streaming or error if too large – but since this is not production, a simpler approach is fine (perhaps allocate a buffer for the entire body unless a streaming mode is used).  
    *Test:* Use the server’s existing streaming endpoints to verify. For example, the server has a `/stream/1gb` route that streams a 1 GiB response with no memory overhead. Have the client request this endpoint and stream the data to /dev/null or compute a checksum. Ensure the client can handle it without running out of memory by processing chunks incrementally (this will test flow control and backpressure handling). Also test a large POST upload: the server’s `/upload/stream` endpoint expects a large body and computes a SHA-256. Use the client to send, say, 100 MB or 1 GiB of data (perhaps generated on the fly), and verify the server’s response (which might include a success or the computed hash). This ensures our client’s send path is robust.

5.  **Milestone C5: QUIC Datagram Support** – *Enable and use QUIC DATAGRAM frames.*  
    *Implementation:* Allow the client to use QUIC datagrams. This involves enabling datagrams in quiche config (`quiche_config_enable_dgram(config, true, recv_queue_len, send_queue_len)`) before connecting. Provide an API on the client like `client.sendDatagram(bytes: []u8)` to send a UDP-style datagram over QUIC (using `quiche_conn_dgram_send`). Received datagrams can be retrieved by calling `quiche_conn_dgram_recv` in the event loop when `quiche_conn_is_readable()` or a datagram-specific API indicates data. We will likely poll for datagrams on each loop iteration after handling stream events. The client can either expose a callback `onDatagram` for the user or queue them in a list for the user to read. We should also handle the case where the peer (server) does not support datagrams – `quiche_conn_dgram_send` will return an error if not negotiated. We can check the peer transport param via `quiche_conn_dgram_max_writable_len` (if this is 0 or negative, peer doesn’t support) or the stats field `peer_max_datagram_frame_size`.  
    *Test:* Use the library’s provided QUIC datagram echo server (`zig build quic-dgram-echo`) which echoes any received datagram. Have the client send a test datagram and verify it receives the echo back. Also test sending datagrams back-to-back (to ensure our send queue handling is correct). Additionally, test behavior when connecting to a server that does not support datagrams (the datagram send should gracefully fail or be a no-op).

6.  **Milestone C6: HTTP/3 DATAGRAM (H3D) and WebTransport** – *Higher-level datagrams and WT sessions.*  
    *Implementation:* Now combine H3 with datagrams. **H3 DATAGRAM:** If both client and server enabled H3 datagram support, then certain datagrams will carry an HTTP/3 *Flow ID* and are associated with a particular request. On the server, this was used for the `/h3dgram/echo` route. For the client, we implement similarly: when the client sends a request that expects to use H3 datagrams (perhaps a special API or header indicates it), the client should register a Flow ID for that request. `quiche_h3_conn_send_request` might allow adding the `Datagram-Flow-Id` header if needed, or we might simply know that the first datagram sent on a request will implicitly create a flow. We maintain a map of `(stream_id, flow_id)` for outgoing H3 datagrams. For incoming, when `quiche_conn_dgram_recv` yields a datagram, we need to parse the H3 datagram header (if present: it's basically a variable-length integer flow ID followed by payload). We can use the same logic as server (the server stored `h3.dgram_flows` mapping flow IDs to request contexts). On client, map flow IDs to something like a `H3DatagramHandler` or tie it to the request’s context. Invoke user callbacks for H3 datagram events (e.g., an `onH3Datagram` callback per request).  
    **WebTransport:** Implement the ability to open a WebTransport session. This means the client sends a CONNECT request to a `/:path` with header `Sec-WebTransport-Http3-Draft02` etc., which quiche abstracts by a flag (the server enabled it via environment variable negotiation). If `H3_WEBTRANSPORT` env is set on both ends, the Extended CONNECT is permitted. The client can simply do:

- const wtStreamId = try client.sendRequest(.{
          .method="CONNECT", .path="/yourWTendpoint", .headers={ "Sec-WebTransport-Http3-Version": "draft02" }
      }, null);

  If the server accepts (status 200), we consider the WebTransport session established with an ID equal to the stream ID. We then allow sending DATAGRAMs on that session by prepending the session ID (as 62-bit varint, value = stream ID) with 0x00 (WT datagram prefix is just the varint of session ID, as server code suggests). The server’s implementation uses environment toggles to allow incoming WT streams and has helpers like `openWtBidiStream` for server-initiated. For the client, we might not need separate helpers to open streams within WT (the client can open streams simply by using `client.sendRequest` with the WT session’s context, but actually in WebTransport, opening a new stream inside the session is just a normal H3 stream with a capsule or with a specific identifier? Actually, WebTransport uses the session ID to bind streams: client-initiated unidirectional streams are implicitly part of the session if they start with 0x41 and the session ID. The server enabled that when H3_WT_BIDI=1. We can similarly allow the client to open substreams if needed: essentially, the client would call something like `client.openWebTransportStream(session_id, bidirectional?)` which would use `quiche_conn_stream_send` to send the WT stream preface bytes (0x54 or 0x41 + session ID) to bind the stream, then allow sending data. Given the complexity and that `quiche` FFI doesn’t explicitly support this high-level, we can start with just the main session establishment and DATAGRAMs, and document that full bidirectional stream usage in WT may require future upstream support).  
  *Test:* Use the server’s WebTransport capability to test the client. For example, if the server has an endpoint `/chat` that upgrades to WebTransport (not sure if implemented, but we can create one). Have the client initiate `CONNECT /chat` with WT enabled. On success, verify the server’s logs that a WT session was created. Then have the client send a datagram on that session (client uses `client.sendWebTransportDatagram(session, data)` which under the hood calls `quiche_conn_dgram_send` with session-id-prefixed data). The server’s `on_wt_dgram` handler (if any) should echo or respond. If possible, test client’s reception of a server-sent WT datagram as well. This will confirm the end-to-end WebTransport datagram flow. Additionally, test that non-WT requests are unaffected when WT is enabled. Since WebTransport is experimental, these tests can be guarded or optional.

7.  **Milestone C7: Robustness & Edge Cases** – *Graceful shutdown, errors, and resource cleanup.*  
    *Implementation:* Finalize error handling paths: e.g., if server sends GOAWAY, ensure new requests are not sent (maybe have `Client` store a flag of max_allowed_stream_id from GOAWAY). If connection closes, ensure all pending requests get an error callback. Implement timeout for no response (perhaps using the QUIC idle timeout – if `max_idle_timeout` is set in config, quiche will trigger timeout events). Also consider what happens if the server requires a Retry or a token: `quiche_connect` may handle this automatically, but if not, we may need to capture `quiche_conn_is_in_early_data` or token needed events from quiche. Logging: reuse the debug log callback to print quiche logs if enabled (server does this via `quiche_enable_debug_logging()` on debug builds). Make sure to free all allocations: H3 conn via `quiche_h3_conn_free`, QUIC conn via `quiche_conn_free` when done (likely our Zig wrapper will manage these in deinit).  
    *Test:* Induce some error conditions: Connect to an invalid port to see error; connect with wrong ALPN (our client only does “h3” so maybe test a failure to negotiate ALPN by forcing a mismatch – not trivial unless we modify server). Test multiple connection close scenarios: server sending GOAWAY (the server can send GOAWAY on shutdown; ensure client handles it), server resetting a stream (maybe have a handler that calls `Response.resetStream()` if implemented, or a server that rejects a request with H3 Reset). Also test the client closing connection mid-stream (call `client.close()` while a download is in progress, and verify server sees a disconnect). Memory leak tests: run multiple requests and check via Zig’s testing allocator or valgrind that no leaks.

8.  **Milestone C8: End-to-End Testing and Integration** – *Combine client & server for full E2E tests.*  
    Now that the client can do everything the server can (in theory), we set up automated tests that launch both in-process or as separate processes:

9.  **In-Process:** We can write a Zig test that creates a `QuicServer` and a `QuicClient` in the same process (perhaps on different threads or interleaved event loops). This is tricky because both want to use libev loop – we might instead run the server in one thread with its loop and the client in another thread with a separate loop. Zig’s std libev bindings might not be thread-safe to have two loops concurrently; if not, an easier approach is to run the server in a subprocess (invoke via `std.ChildProcess`) in tests.

10. **Spawn and Interact:** Use the technique mentioned in our docs – e.g., spawn the Zig server as an external process, then run the Zig client to connect to it. Verify outputs and exit codes. The docs suggest an integration harness was planned. We could also incorporate the `quiche-client` C app as a reference: for instance, run our server and use quiche’s client to fetch a resource, then run our client against quiche’s server to cross-verify behavior. This gives confidence in interoperability.

11. **Bun E2E tests:** The repository already has Bun-based tests under `tests/e2e`, which currently exercise the server using Node/Bun as a client (via fetch or quiche client). We can extend these tests to use our Zig client. For example, a Bun test could call into the Zig client (if exposed via FFI) or just execute the Zig client binary, to fetch known endpoints and compare results.

12. **Logging and QLOG:** We will verify that QLOG output for client exists and contains expected events when enabled (use quic visualization tools on the qlog). Also ensure the client's internal logs (if any) show the handshake and request summaries.

*Test Cases:* Some end-to-end scenarios to automate: - Basic GET and POST between our client and server (verify content and status). - Concurrent requests: e.g., client sends 50 requests, server responds, ensure all delivered. - Large file transfer: upload and download (check data integrity via checksum). - Datagram echo: client sends QUIC datagrams to server echo endpoint, gets them back (both plain QUIC and H3 datagrams). - WebTransport echo: if a simple WT echo is set up, test sending datagram messages through a WT session. - Graceful shutdown: start a request, then stop the server mid-way (server sends GOAWAY and closes), client should handle it (maybe retry connecting? not in scope, but should at least not crash). - Interop: Use our client to fetch from a known public HTTP/3 service (if available) or from `ngtcp2` H3 server, to ensure compatibility beyond quiche.

These tests will give us confidence that the client is functioning correctly in concert with the server.

## Testing Strategy

- **Unit tests:** Stub out quiche entry points where practical and validate request lifecycle/state machines.
- **Integration (in-process) tests:** Run the client against our Zig server within the same test harness to cover routing, streaming, DATAGRAM, and WebTransport flows.
- **Interop tests:** Execute the client against quiche’s example server (cargo target) and, when available, ngtcp2’s HTTP/3 server to confirm protocol compliance.
- **E2E automation:** Extend the Bun test harness to invoke the new `h3-client` CLI and assert responses, datagrams, and WebTransport echoes.
- **qlog verification:** When qlog is enabled, capture client logs and inspect them with existing tooling to ensure handshake/stream events are present.


## Platform Support Notes

Initially, the client will be supported on **Linux and macOS** (POSIX). This aligns with the server’s design which also targets these systems first. We rely on libev, which is available on both. We will ensure IPv4/IPv6 both work (server already handles dual-stack binding; the client can similarly try IPv6 first then fall back to IPv4 if needed, or let DNS resolution guide it).

**Windows:** Out of scope for now, but if needed, potential future work could involve using I/O completion ports or adapting the event loop to Win32. Cloudflare’s quiche does support Windows (using schannel or boringSSL); however, Zig’s libev may not support Windows easily. So we explicitly note Windows as a future consideration, not part of this plan.

## Conclusion

By following this development plan, we will introduce a fully featured HTTP/3 client into the `zig-quiche-h3` project, complementing the existing server. The client will leverage the same `quiche` library and event-driven architecture to support multiplexed HTTP/3 requests, streaming, datagrams, and WebTransport. Each milestone builds up functionality and will be validated with thorough tests, including end-to-end runs against our own server and external implementations. This ensures the client is interoperable and reliable.

Upon completion, the repository will have both an HTTP/3 server and client for Zig, useful for internal experiments, interoperability testing, and as a learning tool for QUIC/HTTP3 in Zig. We will also address the noted server-side TODOs (like timeouts) during this process, improving the overall robustness of the library. With this plan, we can proceed to implement the client in incremental steps and verify each feature against the HTTP/3 specification and real-world scenarios.
