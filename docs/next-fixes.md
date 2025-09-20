# Next Fixes: Streaming / Download / Range Issues

Last updated: 2025-09-20

## Executive Summary

The HTTP/3 DATAGRAM path is fixed and green. The remaining E2E failures cluster around streaming, downloads, and range handling. This document captures symptoms, hypotheses, and a concrete plan to fix them. It will act as the working baseline for the next iteration.

## Snapshot of Failures (from full E2E run, 20s timeout)

- Per‑connection limits
  - Per‑connection download cap [static/dynamic]
    - “rejects second concurrent file download with 503 when cap=1” → timeouts (20s)
    - “does not count memory streaming as downloads” → timeouts (~10s)
  - Per‑connection request cap [static/dynamic]
    - “rejects N+1 requests with 503 when cap=2” → failures (~4.5s), not necessarily timeouts

- Download / streaming endpoints (static & dynamic)
  - /stream/test (10MB): timeouts (10–20s)
  - /download/* file serving: multiple timeouts (~10s) across checksum, 404, traversal, absolute path, empty path
  - Streaming behavior suite: timeouts on partial content ranges, disconnect handling, concurrent downloads

- Range requests (static & dynamic)
  - Invalid Range Headers: quick failures (<5ms)
  - Large File Ranges: timeouts (20s)

## Symptoms & Observations

- Many tests stall rather than fail fast. This suggests either:
  - Response never completes (no body, or backpressure not drained), or
  - Server side is blocked waiting for writable events that never flush, or
  - Range path returns incorrect headers/status leading clients to wait indefinitely.
- Some request‑cap tests fail quickly (not timeout), implying logic/branch mismatch (e.g., caps not applied to the intended counter).

## Hypotheses (most likely first)

1) Writable stream processing regression
   - H3 writable flush path may have changed; if `processWritableStreams` does not drive partial responses or misses flushing, bodies stall.

2) Backpressure / limiter interaction
   - The download limiter or active‑download counters may be gating writes without re‑arming writable or releasing counters on completion/error.

3) Range response framing
   - Range handlers might emit headers inconsistent with the body (e.g., missing Content‑Range, wrong Content‑Length, or status != 206), causing client to wait.

4) File serving resolver
   - The /download/* handler’s path validation could block or error before emitting a proper response; timeouts indicate no terminal status sent.

5) Cap accounting
   - Request/download caps may not decrement on end/error, leaving connections “stuck” at cap.

## Instrumentation Plan

Add temporary debug (guarded by env `H3_DEBUG=1`) in:

- H3 core/writable path
  - src/quic/server/h3_core.zig
    - Log on headers sent, first body chunk queued, partial response flush attempts, trailers, end, and error paths.
    - Log when response transitions to ended and when state is removed/deinit.

- Egress draining
  - src/quic/server/mod.zig (drainEgress & write loops)
    - Log bytes queued/actually sent; re‑arm decisions.

- Download counters / request caps
  - Increment/decrement with stream id + connection id; log on cap rejection branch.

- Range handler
  - When a range is parsed, print computed start/end, chosen status (206/200/416), and headers.

Note: Keep logs behind `H3_DEBUG=1` to avoid noisy CI.

## Repro Commands (manual)

- 10MB stream:
  - `zig build quic-server -- --port 4433 --cert third_party/quiche/quiche/examples/cert.crt --key third_party/quiche/quiche/examples/cert.key`
  - `./zig-out/bin/h3-client --url https://127.0.0.1:4433/stream/test --insecure --stream --timeout-ms 10000`

- Download file serving:
  - `./zig-out/bin/h3-client --url https://127.0.0.1:4433/download/somefile.bin --insecure --stream`

- Range request:
  - `./zig-out/bin/h3-client --url https://127.0.0.1:4433/stream/test --insecure --headers "range:bytes=0-1023" --stream`

- Caps:
  - In one shell, start two parallel 10MB streams to the same port; expect one to 503 when cap=1.

## Triage Checklist (by area)

1) Writable & partial response
   - [ ] Confirm `processWritableStreams()` is called repeatedly until `partial_response == null`.
   - [ ] Verify backpressure errors (StreamBlocked) re‑arm writable and do not abort the response.
   - [ ] Ensure `end(null)` is executed for non‑streaming handlers and state cleaned.

2) Download caps / counters
   - [ ] On response end/error, decrement active downloads & requests.
   - [ ] Reject branch: return 503 with small body; do not stall.
   - [ ] Confirm counters are per‑connection and reset on close.

3) Range logic
   - [ ] For valid ranges: status 206 + Content‑Range + Content‑Length = segment length.
   - [ ] For invalid ranges: 416 with proper headers.
   - [ ] If multi‑range unsupported, ignore with 200 full body or 416—not stall.

4) File serving
   - [ ] Early error paths (404/403/400) must set status + content‑length: 0 and end.
   - [ ] Path validation: ensure we don’t return without sending a response.

## Fix Plan (ordered)

P0 — unblock streaming
1) Harden writable processing
   - Centralize partial flush + re‑arm logic; add unit test for partial writer.
2) Ensure response end/cleanup runs on all paths (normal, error, backpressure).
3) Cap accounting correctness
   - Decrement on end/error; add asserts in debug builds.

P1 — correctness & range
4) Range handler correctness
   - Emit correct status/headers; reject invalid inputs explicitly.
5) File serving error paths
   - Always emit terminal status; no silent returns.

P2 — robustness & observability
6) Add targeted tests
   - Small range, large range, invalid range, multi‑range ignored.
7) Tighten logs behind H3_DEBUG
   - Keep high‑value debug without flooding normal runs.

## Acceptance Criteria

- No timeouts in streaming/download/range suites with 20s budget.
- Range requests return correct status/headers for valid/invalid cases.
- Cap tests pass deterministically (request+download).
- No resource leaks: active_requests/active_downloads go back to zero on end.

## Risk & Rollback

- Stream flush logic is delicate; isolate changes with guarded feature flags if needed.
- Keep changes minimal and reversible per module (h3_core, server/mod, handlers).

## Ownership & Next Steps

- Owner: (assign)
- Kickoff: instrument logs (H3_DEBUG), triage writable flush path, propose minimal fixes for caps & range.
- ETA: 2–3 working days to green the affected suites once root causes are confirmed.

