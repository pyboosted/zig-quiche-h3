# E2E Test Suite Fix Plan — DATAGRAM Status Update (2025‑09‑20)

## Executive Summary

HTTP/3 DATAGRAM E2E tests are fixed and stable without any arbitrary sleeps. No further changes are required for DATAGRAM functionality.

## What Was Fixed

### 1) Client: Event‑Driven DATAGRAM Send (no sleeps)
- h3-client now sends DATAGRAMs exactly on the first headers event for the request.
- If headers arrived before the client learned the stream_id, we queue a pending send and flush immediately when startRequest() returns the stream_id.
- This guarantees the server’s flow mapping exists when we send, removing timing races.

### 2) Client: Deterministic wait for echoes (condition‑based)
- Added a condition loop (no timers) that runs the event loop until a minimum number of DATAGRAM events are observed, bounded by the existing `--timeout-ms`.
- New flag `--wait-for-dgrams N` (default: N=1 when `--dgram-count > 0`).
- This provides predictability without arbitrary delays.

### 3) Test helper: Preserve streaming prefix
- zigClient preserves any streaming lines that appear before the HTTP/3 header block in `res.raw`.
- Prevents losing `event=datagram` lines in curl‑compat mode.

### 4) Tests: No more `dgramWaitMs`
- Removed all `dgramWaitMs` from DATAGRAM tests. Tests rely on condition‑based completion.

## Current Status

- `basic/h3_dgram.test.ts`: PASS (no sleeps).
- `basic/dgram.test.ts`: PASS (no sleeps).

No further work is required for DATAGRAM functionality.

## Out‑of‑Scope / Future Work

The broader E2E run surfaced timeouts in streaming/download/range suites that are unrelated to DATAGRAM behavior. These will be tracked separately and do not block DATAGRAM features.

## Notes

- The protocol negotiation was already correct; the issue was client timing/observation. Moving to event‑driven send and condition‑based observation resolved it cleanly.
