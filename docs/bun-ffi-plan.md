# Bun FFI Integration Plan

## Purpose
Deliver first-class Bun bindings for the zig-quiche-h3 server and client so Bun applications can embed HTTP/3 (including QUIC DATAGRAM and WebTransport) without spawning child processes. We will surface both long-running server loops and on-demand client fetches through a Bun-friendly API built on the existing C ABI façade.

## Scope
- **In scope**: shared library exports for server + client, Bun-side TypeScript wrappers, lifecycle management, datagram / WebTransport bridging, metrics hooks, and Bun-driven end-to-end tests.
- **Out of scope**: shipping Bun npm packages, Node-API parity, non-HTTP/3 transports.

## Current State Snapshot (2025-09-28)
- Shared library target `libzigquicheh3` already exposes `zig_h3_version()` for smoke tests (see `docs/plan.md`, Pre-M1).
- Server/client implementations are modularized (`src/quic/server/*`, `src/quic/client/*`), and the HTTP/3 client CLI powers Bun E2E tests.
- No production-ready Bun bindings exist; prior experiments only returned version strings.

## High-Level Architecture
1. **Shared Library Layer (Zig)**
   - Extend the existing C ABI façade (`docs/spec.md §17`) for both server and client entry points.
   - Guarantee ABI-stable structs and explicit allocation/free functions.
2. **Runtime Threads**
   - Run libev-backed server loop (and optional client polling) on dedicated Zig threads.
   - Surface event notifications via either thread-safe callbacks or a poll API.
   - Bun callbacks invoked off-thread must set `threadsafe: true` when constructing `JSCallback` to remain safe across threads.citeturn0search0
3. **Bun Binding Layer (TypeScript)**
   - Load `libzigquicheh3` with `dlopen` from `bun:ffi`; define symbol maps with concrete `FFIType` descriptors.
   - Wrap function pointers with typed helpers and RAII-style classes (e.g., `ServerHandle`, `ClientHandle`).
   - Manage callback lifetimes via `JSCallback` and clean up using `.close()` once handles are freed.citeturn0search2
4. **Concurrency & Workers**
   - For cross-thread callbacks triggered by the Zig loop, prefer dispatching onto Bun `Worker`s to match Bun’s recommendation for thread-safe callbacks.citeturn0search6
   - Provide a polling alternative (`zig_h3_next_event`) for runtimes unwilling to spawn thread-safe callbacks.
5. **Testing & Tooling**
   - Add Bun integration tests that boot the server via FFI, issue client requests through both the FFI client and existing CLI, and assert datagram telemetry.
   - Extend CI scripts to build the shared library and run Bun tests on macOS + Linux (x86_64, aarch64 where available).

## Implementation Milestones

### M0 — Foundation & Build Outputs
- [x] Define `zig build bun-ffi` target producing `libzigquicheh3` (macOS `.dylib`, Linux `.so`); symbol versioning will be layered on with the expanded ABI in M1.
- [x] Ensure the build artifacts ship alongside headers describing the C ABI.
- [x] Document environment variables for locating the library from Bun (e.g., `process.env.ZIG_H3_LIBDIR`).

**Build Output Notes**
- Running `zig build bun-ffi` places `libzigquicheh3.{dylib,so}` under `zig-out/lib/` and installs the C header at `zig-out/include/zig_h3.h`.
- Bun tooling can locate the library by setting `process.env.ZIG_H3_LIBDIR` (defaults to `${projectRoot}/zig-out/lib`) and resolving the header via `${projectRoot}/zig-out/include`.

### M1 — Server FFI Surface
- [x] Implement `zig_h3_server_new/free/start/stop` plus configuration struct ingestion.
- [x] Expose routing registration APIs (requests, H3 DATAGRAM, WebTransport) with opaque handle lifetimes.
- [x] Provide request/response helpers (status/headers/body, streaming controls, trailers, DATAGRAM send).
- [x] Deliver thread-safe callback support via Bun `JSCallback`/Worker guidance; no polling API required.

### M2 — Client FFI Surface
- [x] Expose `zig_h3_client_new/free/connect` plus configuration ingestion for basic clients.
- [x] Implement fetch issuance with callback results and DATAGRAM send/receive hooks.
- [ ] Add streaming/event callbacks (collect_body = 0), cancellation, and request timeouts.
- [ ] Provide WebTransport session APIs mirroring the server façade.
- [ ] Deliver connection pooling helpers or document reuse strategy.

### M3 — Bun TypeScript Bindings
- [ ] Create `src/bun/server.ts` and `src/bun/client.ts` wrappers encapsulating the FFI map, pointer management, and error translation.
- [ ] Implement automatic conversion between Bun `Headers`, `Request`, `Response` objects and native header lists.
- [ ] Build utilities for converting Bun `ArrayBuffer`/`TypedArray` payloads to native memory buffers and zero-copy read views.
- [ ] Establish structured logging + metrics callbacks with opt-in `JSCallback` wiring.

### M4 — End-to-End & Stress Tests
- [ ] Add Bun test suites that:
  - [ ] Launch the Zig server through FFI, register basic + streaming + WebTransport routes.
  - [ ] Drive requests via the FFI client and verify HTTP status, headers, body integrity, and range handling.
  - [ ] Exchange QUIC and H3 DATAGRAMs, validating drop counters and flow IDs.
  - [ ] Spin up concurrent clients to exercise connection pooling and backpressure.
  - [ ] Validate clean shutdown (`zig_h3_stop`) and resource release (calling `.close()` on callbacks).citeturn0search2
- [ ] Gate stress variants behind `H3_STRESS=1` (reuse existing convention) to exercise 100+ datagram bursts and concurrent streams.
- [ ] Integrate tests into CI, ensuring shared library paths resolve on runners.

### M5 — Observability & Performance
- [ ] Expose qlog controls and stats getters (`zig_h3_stats_snapshot`) for Bun consumption.
- [ ] Add benchmark scripts comparing Bun FFI client vs. CLI binary for latency and throughput.
- [ ] Publish developer documentation (`docs/bun-ffi-usage.md`) with install instructions, code samples, and troubleshooting (callback leaks, pointer misuse).

## Testing Strategy Summary
- **Unit tests (Zig)**: Continue using `zig test src/quic/client/tests.zig` and new FFI-focused unit tests verifying ABI invariants.
- **Bun integration tests**: New suites under `tests/bun/` covering server lifecycle, client fetches, datagram transport, WebTransport, and stress scenarios.
- **E2E parity**: Existing Bun E2E (`tests/e2e`) remains as regression safety net, with new helper utilities reusing FFI bindings to avoid duplicate logic.
- **CI**: Extend workflows to build dynamic libs, run Bun tests on macOS 14 and Ubuntu 22.04 (x86_64). Add optional aarch64 job once runners are available.

## Risks & Mitigations
- **Thread safety of callbacks** — Bun’s thread-safe JSCallback support is still experimental; emphasize Worker-based dispatch and document how to construct `JSCallback` with `threadsafe: true`.citeturn0search6
- **Resource leaks** — Require explicit `close`/`free` methods and add Bun wrappers that automatically dispose via `FinalizationRegistry` for best-effort cleanup.
- **Platform differences** — Validate dlopen paths and calling conventions on macOS/Linux; add automated smoke tests invoking `zig_h3_version()` before running suites.
- **FFI instability** — Version exported symbols (e.g., `zig_h3_server_new_v1`) and maintain semver doc for breaking changes.

## Deliverables
1. Updated shared library build target with documented C headers.
2. Bun TypeScript wrapper package (internal) with typed API for server and client.
3. Comprehensive Bun-based test suites integrated into CI.
4. Documentation covering setup, API usage, and troubleshooting.

## Success Criteria
- Bun applications can start/stop the Zig HTTP/3 server, register routes, and handle requests without processes.
- Bun code can issue HTTP/3/WebTransport requests via FFI client and receive events for datagrams and streaming bodies.
- CI passes on macOS & Linux with Bun tests and existing Zig suites.
- Documentation clearly describes the ABI, Bun integration, and testing workflow.
