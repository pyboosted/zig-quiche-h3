# HTTP/3 Client Status & Roadmap

**Updated 2025-09-28** — The Zig HTTP/3 client now ships as the default harness for end-to-end testing and production scenarios. Core functionality (streaming requests, datagrams, WebTransport, connection pooling, rate limiting, TLS controls) is implemented and exercised in CI. The focus has shifted from feature parity to deeper coverage, interoperability, and polish of the developer ergonomics.

## Implemented Capabilities
- **HTTP/3 core**: handshake, header/body streaming, trailers, graceful GOAWAY, and request cancellation paths validated via `src/quic/client/mod.zig` and companion modules in `src/quic/client/`.
- **Concurrency & pooling**: true parallel fetches with `--repeat` / pooled connections underpin the request cap suites (`tests/e2e/limits/requests_cap.test.ts`).
- **Rate limiting & large transfers**: download caps and streaming generators remain stable against `/stream/test` and `/download/*` handlers.
- **Datagram support**: H3 and plain QUIC datagrams share routing via `src/quic/client/datagram.zig`; metrics counters surface in both client and server logs.
- **WebTransport**: Extended CONNECT negotiation, session lifecycle, datagram queues, and client-initiated uni/bidi streams implemented across `webtransport_core.zig`, `webtransport.zig`, and `webtransport_streams.zig`.
- **CLI tooling**: `zig build h3-client` produces the test/client binary with curl-compatible output, JSON mode, WebTransport and datagram toggles (`src/examples/h3_client.zig`).
- **Test harness**: `tests/e2e/helpers/zigClient.ts` replaces curl helpers; suites call `get/post/zigClient` wrappers directly.

## Recent Highlights (Q3 2025)
- **Event-loop stability**: timer-driven handlers (`/slow`, `/stream/test`) now rely on libev scheduling, eliminating race conditions seen with sleeps.
- **Streaming correctness**: `PartialResponse` integration ensures download caps apply consistently; HEAD responses respect range semantics without body emission.
- **WebTransport hardening**: queue-backed datagram delivery, stream preface encoding, and GOAWAY awareness prevent leaks and double frees.
- **FFI coverage**: wrappers such as `H3Connection.extendedConnectEnabledByPeer()` and CA bundle loaders unblock advanced configuration without patching C code.

## Testing & Coverage Snapshot
- **E2E suites**: Entire limits, streaming, routing, and basic suites run through `zigClient`. Two H3 DATAGRAM negative-path tests remain skipped pending bespoke harness support, and the HEAD+Range case is still gated awaiting a deterministic checker beyond curl.
- **Stress**: High-load variants execute when `H3_STRESS=1`; default CI omits them. Manual stress reporting lives inside the test files (`tests/e2e/streaming/upload_stream.test.ts`).
- **Unit tests**: `zig test src/quic/client/tests.zig` covers fetch lifecycle, datagram parsing, and connection pooling edge cases.
- **Observability**: qlog generation is wired for both client and server; qlogs land under `qlogs/client/` when enabled.

## Current Gaps & Open Work
1. **E2E parity gaps**
   - Implement harness assertions for unknown-flow and varint-boundary DATAGRAM cases (currently TODOs in `tests/e2e/basic/h3_dgram.test.ts`).
   - Replace the skipped HEAD+Range test with a Zig-driven assertion or document a known quiche/curl limitation that still affects the client.
   - Expand WebTransport coverage beyond happy-path echo once a richer server harness ships.
2. **Interoperability**
   - Run targeted smoke suites against `cloudflare/quiche`, `nginx-quic`, `Caddy/quic-go`, `h2o`, and `ngtcp2+nghttp3`. Capture findings in a new compatibility matrix doc.
3. **Performance & Benchmarks**
   - Stand up benchmark scripts under `tests/e2e/benchmarks/` covering connection setup, pooled vs sequential throughput, large transfer latency, and datagram RTT under load.
   - Automate comparisons against curl/quiche-client for historical baselines.
4. **WebTransport limitations (upstream blocked)**
   - Peer-initiated WT streams and richer capsule APIs remain unavailable via the quiche C API; track upstream progress and document workarounds.
5. **Developer experience**
   - Add troubleshooting guidance (certificate failures, datagram queue exhaustion, pool errors) to `docs/client-usage.md`.
   - Evaluate exposing structured metrics/log levels from the CLI for CI ingestion.

## Near-Term Plan
| Priority | Work Item | Owner (TBD) | Notes |
|----------|-----------|-------------|-------|
| P0 | Re-enable HEAD+Range validation with deterministic checker | | Determine whether the remaining issue is server-side or harness-side; adjust test skip reason if still blocked. |
| P0 | Add negative-path DATAGRAM coverage | | Extend `zigClient` JSON mode to surface drop counters, then assert in E2E tests. |
| P1 | Launch interoperability smoke runs | | Use Docker-based targets; capture deviations per stack. |
| P1 | Introduce benchmark harness | | Scripts should generate repeatable outputs consumable by CI. |
| P2 | Expand WT test coverage | | Requires richer server fixtures (`/wt/`). |
| P2 | Author troubleshooting appendix | | Fold into `docs/client-usage.md` or new doc. |

## Operational Notes
- Build the client with `zig build h3-client`; run suites via `bun test tests/e2e` (set `H3_STRESS=1` for stress mode).
- For manual WT validation, launch `zig build quic-server -- --port 4433 --cert … --key …` and run `zig build wt-client -- https://127.0.0.1:4433/wt/echo`.
- qlogs are disabled by default; enable via `H3_QLOG_DIR=./qlogs/client` to capture traces.

## Historical Documents
The standalone refactoring and E2E migration plans have been retired. Their actionable items are either complete (client module split, zigClient adoption) or tracked in the gap list above. Keep future roadmap updates consolidated in this document.
