# WebTransport Implementation Plan

## Current Baseline (2025-02)
- **Server** – Helper APIs exist for WT streams and datagrams (`src/quic/server/webtransport.zig`), but no code currently instantiates `WebTransportSession` objects or wires them into request handling. `WebTransportSessionState.init` is only exercised in tests, and `processH3` never inspects CONNECT requests, leaving `self.wt.sessions` empty.
- **Client** – `QuicClient.openWebTransport` establishes Extended CONNECT and `WebTransportSession.sendDatagram` sends real QUIC datagrams (`src/quic/client/webtransport.zig:45`), but the client lacks stream helpers, capsule handling, and close semantics beyond a FIN stub.
- **Examples & Tooling** – `src/examples/wt_client.zig` is a stub that fakes session success; server examples export no WT routes.
- **Tests & Automation** – No WT-focused unit or E2E coverage; Bun harness relies on the mock client.
- **Feature Toggles** – Build flag `-Dwith-webtransport` (default true) and env vars `H3_WEBTRANSPORT`, `H3_WT_STREAMS`, `H3_WT_BIDI` gate functionality.

## Goals
- Deliver end-to-end WebTransport support aligned with draft-ietf-webtrans-http3 (session negotiation, datagrams, uni/bidi streams, capsules, graceful close).
- Provide usable server and client APIs plus runnable examples and automated tests.
- Preserve optionality via existing build/runtime toggles and maintain observability (metrics, logging, qlog hooks).

## Non-Goals
- Implementing generic CONNECT-UDP or WebSockets.
- Expanding quiche's C FFI beyond what is needed for WT (upstream changes tracked separately).
- Shipping production-ready congestion/perf tuning beyond basic limits.

## Milestones

### Milestone 1 – Server Handshake & Session Tracking
**Goal**: Recognise WT CONNECT requests, create sessions, and expose them to routing callbacks.

**Checklist**
- [ ] Detect `:method = CONNECT` + `:protocol = webtransport` in `processH3` and flag the request state.
- [ ] Instantiate `h3.WebTransportSession` and `WebTransportSessionState` and store them in `self.wt.sessions` / `self.wt.dgram_map`.
- [ ] Extend routing API to surface `OnWebTransportSession`, invoking it after sending 200 OK.
- [ ] Ensure cleanup on stream FIN, GOAWAY, connection close, and idle timeout (reuse `expireIdleWtSessions`).
- [ ] Emit structured logs/metrics for session lifecycle; increment `sessions_created`/`sessions_closed`.

**Exit Criteria**
- Server can accept a WT CONNECT and hand a live session object to a handler.
- Session teardown frees allocator resources with no leaks (verified via existing arena checks).

### Milestone 2 – Server Datagrams & Stream IO
**Goal**: Make WT sessions useful by delivering datagrams/streams to application callbacks.

**Checklist**
- [ ] Implement `WebTransportSession.sendDatagram` wrapper on server side and expose it through handler APIs.
- [ ] Route incoming H3 DATAGRAMs with session flow IDs to session `on_datagram` callbacks.
- [ ] Wire uni/bidi stream open/data/close callbacks (`OnWebTransportUniOpen`, `OnWebTransportBidiOpen`, etc.) once `self.wt.enable_streams` is true.
- [ ] Handle backpressure for outgoing streams using existing pending queues; surface `error.WouldBlock` consistently.
- [ ] Add targeted unit tests for datagram parsing and uni-stream preface binding.

**Exit Criteria**
- A handler can echo WT datagrams and observe client-initiated uni streams.
- Streams/datagrams survive short backpressure and are accounted for in metrics.

### Milestone 3 – Capsule & Error Semantics
**Goal**: Align with the WT capsule protocol for acceptance, parameters, and closure.

**Checklist**
- [ ] Implement capsule encode/decode helpers (SESSION_ACCEPT, SESSION_CLOSE, possibly STREAM_DATA_BLOCKED) on CONNECT stream.
- [ ] Allow handlers to accept/reject sessions with capsule payloads before sending 200/4xx as appropriate.
- [ ] Propagate WT-specific application error codes on stream shutdown (use constants in `h3/webtransport.zig`).
- [ ] Update metrics/logging to record capsule exchanges and error paths.

**Exit Criteria**
- Session negotiation communicates limits (e.g., max datagram size) via capsules.
- Rejecting a session sends spec-compliant capsule + status; clients receive structured reason codes.

### Milestone 4 – Client Parity & API Surface
**Goal**: Provide a first-class client that can mirror server capabilities.

**Checklist**
- [ ] Expose datagram send/receive ergonomically (refine error mapping, allow batching when quiche backpressures).
- [ ] Add helpers to open WT uni/bidi streams (prefix generation, send/recv loops, FIN handling) while documenting quiche C API limitations on peer-initiated streams.
- [ ] Implement capsule parsing/sending on the CONNECT stream to consume SESSION_ACCEPT/SESSION_CLOSE.
- [ ] Support explicit `close(code, reason)` and surface server-initiated closes to the caller.
- [ ] Add configuration knobs (limits, timeout) mirrored from `ServerConfig`.

**Exit Criteria**
- `QuicClient.openWebTransport` returns a session capable of datagram echo and initiating uni/bidi streams under spec limits.
- Client surfaces close/error events distinctly from network failures.

### Milestone 5 – Examples, Tests, and Interop
**Goal**: Replace stubs with runnable demos and automated coverage.

**Checklist**
- [ ] Replace `src/examples/wt_client.zig` with a real client using `QuicClient` (CLI flags for mode, payload, counts).
- [ ] Add a WT route to `quic_server.zig` (echo datagrams and uni streams) guarded by env toggles.
- [ ] Extend Zig unit tests (`src/tests.zig`) for session handshake and datagram round trip using in-process server/client.
- [ ] Add Bun E2E tests exercising datagrams and streams; enable stress mode with `H3_STRESS=1`.
- [ ] Document usage in README/docs (flags, example commands, troubleshooting) and collect qlogs for interop runs.

**Exit Criteria**
- `zig build wt-client` talks to `zig build quic-server` over real WT, covering datagrams + streams.
- `zig build test` and `bun test tests/e2e` include WT scenarios and pass in CI.
- Docs clearly describe enabling WT and known limitations.

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
