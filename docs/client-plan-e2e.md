# E2E Testing Enhancement Plan

## Executive Summary

This document tracks the migration from curl to our native `zig-quiche-h3` client in the E2E suite. With the latest client/server updates (2025-09-22), the HTTP/3 request-cap and download-cap suites now run entirely on the Zig client with real concurrency, and `/slow`/`/stream/test` handlers behave deterministically under load. Remaining skips are limited to protocol edge cases blocked by upstream tooling.

> **Goal**: Complete Week 3 of the client implementation plan by creating a production-ready HTTP/3 test client that enables comprehensive E2E testing.

## Progress Checklist

### Foundation
- [x] Ship curl-compatible `h3-client` CLI with repeat/concurrency, DATAGRAM, and WebTransport toggles
- [x] Replace curl helper with `zigClient()` wrapper across the E2E suite
- [x] Stabilise server handlers (`/slow`, `/stream/test`) for timer-driven streaming

### Suites & Coverage
- [x] Run request/download cap suites through the Zig client with true parallelism
- [x] Re-enable stress variants gated by `H3_STRESS`
- [ ] Replace curl for HEAD + Range once upstream HTTP/3 bug is fixed or alternate probe is available
- [ ] Add regression coverage for H3 DATAGRAM negative-path tests (unknown flow-id, varint boundaries)

### Stretch Goals
- [ ] Stand up compatibility matrix (nginx-quic, Caddy, h2o, ngtcp2)
- [ ] Benchmark Zig client vs curl/quiche-client for handshake and throughput
- [ ] Layered logging/metrics for long-running soak tests

## Current Testing Limitations

### Skipped Tests Analysis

Our E2E test suite currently has **a handful of skipped tests**—primarily curl-specific limitations and TODO placeholders awaiting richer datagram tooling:

#### H3 DATAGRAM TODOs (2 skipped)
- `tests/e2e/basic/h3_dgram.test.ts`
  - "unknown flow_id handling"
  - "varint encoding/decoding boundary cases"

#### Protocol Edge Cases (1 skipped + stress-gated cases)
- `tests/e2e/streaming/ranges.test.ts`
  - "returns correct headers for HEAD with range" (curl HTTP/3 bug - exit code 18)
- Stress tests that need `H3_STRESS=1` environment variable

### Current Test Infrastructure

```typescript
// tests/e2e/helpers/curlClient.ts
export async function curl(url: string, options: CurlOptions): Promise<CurlResponse> {
    const args = [
        "curl",
        "-sk",           // Silent, insecure
        "--http3-only",  // Force HTTP/3
        "-i",           // Include headers
        "--raw",        // Disable HTTP decoding
    ];
    // ... limited to basic HTTP/3 features
}
```

## Implementation Plan & Tracking

### Phase 1 – CLI Parity *(Complete)*
- [x] Ship `h3-client` with curl-compatible flags and extended options (DATAGRAM, WebTransport, concurrency)
- [x] Preserve detailed error propagation from `QuicClient.init` (CA bundle, libev, etc.)

### Phase 2 – Test Harness Integration *(Complete)*
- [x] Replace `curlClient.ts` with `zigClient.ts`
- [x] Keep backwards-compatible helpers (`get`, `post`, etc.) that now delegate to Zig

### Phase 3 – Unlock Skipped Suites *(In Progress)*
- [x] Limits: concurrent request cap
- [x] Limits: download cap (memory vs file streaming)
- [ ] Streaming: HEAD + Range (blocked on curl HTTP/3 limitation – needs alternate probe)
- [ ] H3 DATAGRAM negative paths (requires richer client harness)

### Phase 4 – Multi-Server Compatibility *(Not Started)*
- [ ] quiche-server (Cloudflare) smoke tests via Docker
- [ ] nginx-quic compatibility run
- [ ] Caddy / quic-go compatibility run
- [ ] h2o / picoquic compatibility run
- [ ] ngtcp2 + nghttp3 compatibility run

### Phase 5 – Performance Benchmarks *(Not Started)*
- [ ] Handshake latency comparison (curl vs zigClient, pooled vs non-pooled)
- [ ] Request throughput (sequential vs pooled vs concurrent)
- [ ] Streaming throughput (large downloads/uploads with caps)

Test our client against various HTTP/3 implementations to ensure compatibility. The table doubles as a status board; update the checkboxes as runs complete.

| Server Stack | Coverage Target | Status | Notes |
|--------------|-----------------|--------|-------|
| `zig-quiche-h3` (local) | Full regression suite | ✅ Done | Runs in CI after recent concurrency fixes |
| `cloudflare/quiche` | Smoke (GET/POST, DATAGRAM) | ☐ Planned | Launch via docker-compose target |
| `nginx-quic` | Basic HTTP/3 GET/HEAD | ☐ Planned | Requires custom image with certs |
| `Caddy` (quic-go) | Basic HTTP/3 GET/POST | ☐ Planned | Validate WebTransport once upstream support lands |
| `h2o` (picoquic) | Basic HTTP/3 | ☐ Planned | Focus on response header parity |
| `ngtcp2 + nghttp3` | Full | ☐ Planned | Ideal for priority/resumption experiments |

### Phase 5: Performance Benchmarks (Storyboard)

Benchmark harnesses will live under `tests/e2e/benchmarks/`. Each scenario gets a checkbox once the script and baseline numbers exist.

- [ ] Connection establishment (single vs pooled)
- [ ] Parallel request throughput (10/100/1000 requests)
- [ ] Streaming throughput (10 MB / 100 MB bodies with/without rate limits)
- [ ] DATAGRAM round-trip latency under load

3. **Large File Transfer**
   ```typescript
   bench("curl 100MB download", async () => {
       await curl("https://localhost:4433/large");
   });

   bench("zigClient 100MB download with streaming", async () => {
       await zigClient("https://localhost:4433/large", { stream: true });
   });
   ```

4. **Memory Usage**
   ```typescript
   bench.memory("curl memory usage", async () => {
       await curl("https://localhost:4433/large");
   });

   bench.memory("zigClient memory usage", async () => {
       await zigClient("https://localhost:4433/large");
   });
   ```

#### Expected Results

| Metric | curl | zigClient | Improvement |
|--------|------|-----------|-------------|
| Connection Setup | 15ms | 14ms | ~7% faster |
| 100 Requests (sequential) | 1500ms | 1400ms | ~7% faster |
| 100 Requests (pooled) | N/A | 300ms | 5x faster |
| 100MB Transfer | 850ms | 820ms | ~4% faster |
| Memory Usage | 45MB | 35MB | ~22% less |

### Phase 6: Documentation

#### User Documentation (`docs/client-usage.md`)

```markdown
# zig-quiche-h3 Client Usage Guide

## Installation
```bash
zig build h3-client
cp zig-out/bin/h3-client /usr/local/bin/
```

## Basic Usage

### HTTP/3 Requests
```bash
# GET request
h3-client https://example.com/

# POST with data
h3-client -X POST -d "data" https://example.com/api

# Custom headers
h3-client -H "Authorization: Bearer token" https://example.com/
```

### Advanced Features

#### H3 DATAGRAMs
```bash
h3-client --h3-dgram --dgram-data "payload" https://example.com/dgram
```

#### WebTransport
```bash
h3-client --webtransport wss://example.com/wt
```

#### Connection Pooling
```bash
# Make 10 concurrent requests using pool
h3-client --concurrent 10 --pool https://example.com/
```

## Migration from curl

| curl | h3-client | Notes |
|------|-----------|-------|
| `curl --http3` | `h3-client` | HTTP/3 by default |
| `curl -X POST` | `h3-client -X POST` | Same syntax |
| `curl -H "Header: Value"` | `h3-client -H "Header: Value"` | Same syntax |
| N/A | `h3-client --h3-dgram` | H3 DATAGRAM support |
| N/A | `h3-client --concurrent N` | True concurrent requests |
```

## Success Metrics

### Test Coverage
- [ ] Enable all 12 currently skipped tests
- [ ] Add 10+ new tests for H3 DATAGRAMs
- [ ] Add 5+ new tests for WebTransport
- [ ] Add 5+ new tests for concurrent requests
- [ ] **Total**: 30+ new test cases enabled

### Performance Goals
- [ ] Connection pooling reduces test suite runtime by >30%
- [ ] Memory usage reduced by >20% compared to curl
- [ ] Support 100+ concurrent connections
- [ ] Handle 10,000+ requests/second

### Compatibility Goals
- [ ] Test against 5+ different H3 server implementations
- [ ] Pass 100% of HTTP/3 conformance tests
- [ ] Support all curl-compatible output formats
- [ ] Maintain backward compatibility with existing tests

## Timeline

### Week 3 Completion (Current)
- [x] QuicClient implementation complete
- [ ] Create h3-client tool (Day 1)
- [ ] Create TypeScript integration (Day 1)
- [ ] Enable skipped tests (Day 2)
- [ ] Multi-server testing (Day 2)
- [ ] Performance benchmarks (Day 3)
- [ ] Documentation (Day 3)

### Future Work
- [ ] Integration with CI/CD pipelines
- [ ] Docker image with h3-client
- [ ] Performance optimization based on benchmarks
- [ ] Additional protocol features as they emerge

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Output format incompatibility | High | Implement curl-compatible output parser |
| Performance regression | Medium | Continuous benchmarking in CI |
| Server compatibility issues | Medium | Test against multiple implementations early |
| Test flakiness | Low | Add retry logic and timeouts |

## Conclusion

Replacing curl with our native h3-client client will unlock comprehensive HTTP/3 testing capabilities, enable all skipped tests, and provide a foundation for testing advanced features like H3 DATAGRAMs and WebTransport. This positions zig-quiche-h3 as a complete HTTP/3 implementation with best-in-class testing coverage.
