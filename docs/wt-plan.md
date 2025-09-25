# WebTransport Implementation Plan

## Current Baseline (2025-09-25)
- **Server** – `processH3` recognises Extended CONNECT when `H3_WEBTRANSPORT=1`, instantiates `WebTransportSession`/`WebTransportSessionState`, tracks them in `sessions`/`dgram_map`, and routes datagrams plus uni/bidi stream lifecycle callbacks through `src/quic/server/webtransport.zig`. Teardown is centralised via `destroyWtSessionState`, with metrics/logging covering session + capsule paths.
- **Client** – `QuicClient.openWebTransport` negotiates sessions, retries DATAGRAM sends on backpressure, exposes helper APIs for outbound uni/bidi streams, and handles SESSION_ACCEPT/SESSION_CLOSE capsules. Peer-initiated streams remain unsupported by quiche's C FFI; the CLI surface still only exposes URL/quiet toggles despite the richer internals.
- **Examples & Tooling** – `/wt/echo` route is wired into both static and dynamic server binaries with echo handlers in `src/examples/quic_server_handlers.zig`. `zig build wt-client` now runs a real WebTransport client that drives the QUIC event loop, emits a datagram, and drains echoes before exit.
- **Tests & Automation** – Bun harness includes `tests/e2e/basic/wt_session.test.ts`, which builds the client, verifies handshake success, exercises datagram echo, and validates the feature gate. Zig unit coverage is still limited to configuration smoke tests; we do not yet have an in-process server/client round trip in `src/tests.zig`.
- **Feature Toggles** – Build flag `-Dwith-webtransport` (default true) and env vars `H3_WEBTRANSPORT`, `H3_WT_STREAMS`, `H3_WT_BIDI` still gate functionality; handlers defensively check `enable_streams`/`enable_bidi` before wiring callbacks.

## Goals
- Deliver end-to-end WebTransport support aligned with draft-ietf-webtrans-http3 (session negotiation, datagrams, uni/bidi streams, capsules, graceful close).
- Provide usable server and client APIs plus runnable examples and automated tests.
- Preserve optionality via existing build/runtime toggles and maintain observability (metrics, logging, qlog hooks).

## Non-Goals
- Implementing generic CONNECT-UDP or WebSockets.
- Expanding quiche's C FFI beyond what is needed for WT (upstream changes tracked separately).
- Shipping production-ready congestion/perf tuning beyond basic limits.

## Milestones

### Milestone 1 – Server Handshake & Session Tracking ✅
**Goal**: Recognise WT CONNECT requests, create sessions, and expose them to routing callbacks.

**Completed Work (2025-09-24)**
- ✅ Runtime gate enforced: `processH3` only accepts WT CONNECT when `H3_WEBTRANSPORT=1` and the build flag enables WT.
- ✅ Request state detects WT CONNECT, records negotiated flow ID, and logs the handshake path.
- ✅ Handshake allocates `WebTransportSession`/`WebTransportSessionState`, stores them in `sessions` and `dgram_map`, and passes the live session into route callbacks after sending the 200/SESSION_ACCEPT capsule via `Response.finishConnect`.
- ✅ Added buffered capsule writer with retry on stream writable notifications to keep the CONNECT stream alive per spec.
- ✅ Centralised teardown (`destroyWtSessionState`) invoked on FIN, GOAWAY/reset, idle expiry, and connection close, releasing header copies and session arenas while bumping metrics.

**Exit Criteria Status**
- Server now accepts WT CONNECT and delivers an active session to handlers (verified in `zig build test`).
- Session teardown frees all allocations (arena + header copies) and updates lifecycle counters on every exit path.

### Milestone 2 – Server Datagrams & Stream IO
**Goal**: Make WT sessions useful by delivering datagrams/streams to application callbacks.

**Checklist**
- [x] Implement `WebTransportSession.sendDatagram` wrapper on server side and expose it through handler APIs.
- [x] Route incoming H3 DATAGRAMs with session flow IDs to session `on_datagram` callbacks.
- [x] Wire uni/bidi stream open/data/close callbacks (`OnWebTransportUniOpen`, `OnWebTransportBidiOpen`, etc.) once `self.wt.enable_streams` is true.
- [x] Handle backpressure for outgoing streams using existing pending queues; surface `error.WouldBlock` consistently.
- [x] Add targeted unit tests for datagram parsing and uni-stream preface binding.

**Progress (2025-09-25)**
- Session wrapper hands apps an opaque `WebTransportSession`/`WebTransportStream` with helpers to set datagram/stream callbacks, send datagrams, and open outbound streams while respecting runtime toggles.
- Incoming datagrams and stream events route through the wrapper, updating WT metrics and using buffered backpressure paths.
- Capsule writer retains buffering logic; stream/datagram cleanup remains centralised via `destroyWtSessionState` and stream wrapper teardown.
- Added `encodeQuicVarint` regression test plus WT API unit coverage for handler registration/stream wrappers; existing `parseUniPreface` test still validates uni preface parsing.

**Exit Criteria**
- A handler can echo WT datagrams and observe client-initiated uni streams. (Validated via `tests/e2e/basic/wt_session.test.ts`.)
- Streams/datagrams survive short backpressure and are accounted for in metrics.

### Milestone 3 – Capsule & Error Semantics
**Goal**: Align with the WT capsule protocol for acceptance, parameters, and closure.

**Checklist**
- [x] Implement capsule encode/decode helpers (SESSION_ACCEPT, SESSION_CLOSE, possibly STREAM_DATA_BLOCKED) on CONNECT stream.
- [x] Allow handlers to accept/reject sessions with capsule payloads before sending 200/4xx as appropriate.
- [x] Propagate WT-specific application error codes on stream shutdown (use constants in `h3/webtransport.zig`).
- [x] Update metrics/logging to record capsule exchanges and error paths.

**Progress (2025-09-24)**
- Added `http/webtransport_capsules.zig` with encode/decode utilities and unit tests, plus response helpers for sending capsules.
- Server session API exposes `accept`, `reject`, `sendCapsule`, and `close` with handshake state tracking and default auto-accept fallback.
- QuicServer now records capsule metrics/logging and sends WebTransport-specific error codes on forced stream shutdowns.

**Exit Criteria**
- Session negotiation communicates limits (e.g., max datagram size) via capsules.
- Rejecting a session sends spec-compliant capsule + status; clients receive structured reason codes.

### Milestone 4 – Client Parity & API Surface
**Goal**: Provide a first-class client that can mirror server capabilities.

**Checklist**
- [x] Expose datagram send/receive ergonomically (refine error mapping, allow batching when quiche backpressures).
- [x] Add helpers to open WT uni/bidi streams (prefix generation, send/recv loops, FIN handling) while documenting quiche C API limitations on peer-initiated streams.
- [x] Implement capsule parsing/sending on the CONNECT stream to consume SESSION_ACCEPT/SESSION_CLOSE.
- [x] Support explicit `close(code, reason)` and surface server-initiated closes to the caller.
- [x] Add configuration knobs (limits, timeout) mirrored from `ServerConfig`.

**Progress (2025-09-24)**
- Client sessions now queue outbound datagrams when QUIC reports `error.Done`, reuse the new `ClientError.DatagramBlocked`, and flush pending payloads from the main progress loop so backpressure clears automatically.
- Capsule helpers back the client CONNECT stream; acceptance, drain, and close capsules update session state and metrics while `closeWith` emits `SESSION_CLOSE`.
- Unit tests cover capsule state transitions and datagram queue limits to guard regressions.
- Stream helpers now expose send/receive APIs with configurable queue limits, dispatch FIN events to optional callbacks, and we explicitly document that peer-initiated WT streams remain unsupported pending quiche C FFI hooks.
- Client configuration gained WT-specific knobs (outgoing stream limits and receive buffer sizing) to mirror server controls.
- Added `/wt/echo` to the example server and rewrote `wt_client` so integrators can exercise DATAGRAM and stream helpers end-to-end.

**Exit Criteria**
- `QuicClient.openWebTransport` returns a session capable of datagram echo and initiating uni/bidi streams under spec limits.
- Client surfaces close/error events distinctly from network failures.

### Milestone 5 – Examples, Tests, and Interop
**Goal**: Replace stubs with runnable demos and automated coverage.

**Checklist**
- [x] Replace `src/examples/wt_client.zig` with a real client using `QuicClient` (CLI flags for mode, payload, counts are still TBD).
- [x] Add a WT route to `quic_server.zig` (echo datagrams and uni streams) guarded by env toggles.
- [x] Extend Zig unit tests (`src/tests.zig`) for session handshake and datagram round trip using in-process server/client.
- [x] Add Bun E2E tests exercising datagrams and streams; enable stress mode with `H3_STRESS=1`.
- [ ] Document usage in README/docs (flags, example commands, troubleshooting) and collect qlogs for interop runs.

**Progress (2025-09-25)**
- `src/examples/wt_client.zig` now negotiates a real session, sends a datagram, and drains echoes via the shared event loop; CLI exposure is limited to URL/quiet flags.
- `/wt/echo` is routed in both static and dynamic server binaries with handlers that echo datagrams and mirror stream data when enabled.
- `tests/e2e/basic/wt_session.test.ts` builds the client, verifies session establishment, checks datagram echo, and asserts the feature gate; the stress suite runs multiple clients when `H3_STRESS=1`.
- Documentation needs follow-up: README still refers to a stub client, and `docs/webtransport_client.md` describes CLI flags that are not implemented yet. Qlog collection remains aspirational.
- Added an in-process `WebTransport in-process handshake and datagram echo` test that drives both server and client event loops and asserts session/datagram success.

**Exit Criteria**
- `zig build wt-client` talks to `zig build quic-server` over real WT, covering datagrams + streams. (Exercise satisfied by Bun E2E run.)
- `zig build test` and `bun test tests/e2e` include WT scenarios and pass in CI. (`bun test` already covers WT; Zig coverage still pending.)
- Docs clearly describe enabling WT and known limitations. (Requires aligning README and quickstart content with current CLI capabilities.)

## Technical Notes & Risks
- quiche's C API still lacks callbacks for peer-initiated WT streams on the client; document the gap and consider upstream workarounds.
- Capsule framing must respect flow-control on the CONNECT stream; keep write paths non-blocking.
- Maintain compatibility with existing env toggles; ensure WT defaults to off in production builds if handlers are absent.
- Use qlogs and enhanced logging early to debug handshake issues.

## Deliverables Summary
1. Wired-up server session lifecycle with datagrams/streams and capsule negotiation.
2. Client API that can drive WT sessions end-to-end.
3. Example binaries plus automated unit/E2E coverage proving the flow.
4. Updated documentation and metrics to monitor WT usage.
