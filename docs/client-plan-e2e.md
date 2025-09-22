# E2E Testing Enhancement Plan

## Executive Summary

This document tracks the migration from curl to our native `zig-quiche-h3` client in the E2E suite. With the latest client/server updates (2025-09-22), the HTTP/3 request-cap and download-cap suites now run entirely on the Zig client with real concurrency, and `/slow`/`/stream/test` handlers behave deterministically under load. Remaining skips are limited to protocol edge cases blocked by upstream tooling.

> **Goal**: Complete Week 3 of the client implementation plan by creating a production-ready HTTP/3 test client that enables comprehensive E2E testing.

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

## Implementation Plan

### Phase 1: Create curl-compatible CLI (`h3-client`)

**File**: `src/examples/h3_client.zig`

```zig
const CliArgs = struct {
    url: []const u8,
    method: []const u8 = "GET",
    headers: []const u8 = "",
    data: []const u8 = "",
    output: []const u8 = "-",  // stdout
    insecure: bool = false,
    include_headers: bool = false,
    verbose: bool = false,
    // Extended features
    h3_dgram: bool = false,
    webtransport: bool = false,
    concurrent: u32 = 1,
    pool_connections: bool = true,
};
```

**Features**:
- Drop-in curl replacement for basic HTTP/3
- Extended capabilities for H3 DATAGRAMs and WebTransport
- Connection pooling for true concurrent requests, preserving underlying `QuicClient.init` failures (CA bundle, libev, etc.) instead of misreporting pool exhaustion
- Compatible output format for existing test parsers

### Phase 2: TypeScript Integration Layer

**File**: `tests/e2e/helpers/zigClient.ts`

```typescript
import { spawn } from "bun";

export interface ZigClientOptions extends CurlOptions {
    // Extended options
    h3Dgram?: boolean;
    webTransport?: boolean;
    concurrent?: number;
    poolConnections?: boolean;
}

export async function zigClient(url: string, options: ZigClientOptions = {}): Promise<CurlResponse> {
    const args = ["./zig-out/bin/h3-client"];

    // Build curl-compatible arguments
    if (options.insecure) args.push("--insecure");
    if (options.includeHeaders) args.push("-i");
    if (options.method) args.push("-X", options.method);

    // Extended features
    if (options.h3Dgram) args.push("--h3-dgram");
    if (options.concurrent) args.push("--concurrent", options.concurrent.toString());

    args.push(url);

    const proc = spawn({ cmd: args, stdout: "pipe", stderr: "pipe" });
    // Parse response in curl-compatible format
    return parseCurlResponse(await proc.stdout);
}

// Backward compatibility
export const curl = zigClient;
export const get = (url: string, opts?: ZigClientOptions) => zigClient(url, { ...opts, method: "GET" });
export const post = (url: string, body: any, opts?: ZigClientOptions) => zigClient(url, { ...opts, method: "POST", body });
```

**Error handling**: Because `ConnectionPool.acquire` now returns a `ClientError || QuicClientInitError`, the CLI exits with precise causes (`error.LoadCABundleFailed`, `error.LibevInitFailed`, genuine exhaustion) that the harness can distinguish during setup. The new `tests/e2e/helpers/zigClient.ts` wraps these semantics and replaces the old curl shim for all HTTP/3/H3 DATAGRAM suites.

### Phase 3: Enable Skipped Tests

All formerly skipped **concurrent request** and **download cap** tests now execute through `zigClient`, and the `/slow` handler’s timer-based implementation keeps the event loop responsive. Remaining items in this phase are the curl-specific HEAD + Range case and the two TODO DATAGRAM scenarios above.

### Phase 4: Multi-Server Compatibility Testing

Test our client against various HTTP/3 implementations to ensure compatibility:

#### Test Matrix

| Server | Implementation | Test Coverage | Status |
|--------|---------------|--------------|---------|
| quiche-server | Cloudflare quiche | Full | ✅ Working |
| zig-quiche-h3 | Our server | Full | ✅ Working |
| nginx-quic | nginx + quiche | Basic HTTP/3 | 🔄 Planned |
| Caddy | Go + quic-go | Basic HTTP/3 | 🔄 Planned |
| h2o | picoquic | Basic HTTP/3 | 🔄 Planned |
| ngtcp2 | ngtcp2 + nghttp3 | Full | 🔄 Planned |

#### Implementation

```typescript
// tests/e2e/compatibility/multi_server.test.ts
describe("Multi-Server Compatibility", () => {
    const servers = [
        { name: "quiche", image: "cloudflare/quiche:latest", port: 8443 },
        { name: "nginx", image: "nginx:quic", port: 8444 },
        { name: "caddy", image: "caddy:h3", port: 8445 },
    ];

    for (const server of servers) {
        describe(`${server.name} compatibility`, () => {
            beforeAll(async () => {
                await startDockerServer(server);
            });

            test("basic GET request", async () => {
                const response = await zigClient(`https://localhost:${server.port}/`);
                expect(response.status).toBe(200);
            });

            test("POST with body", async () => {
                const response = await post(`https://localhost:${server.port}/echo`, "test");
                expect(response.body).toBe("test");
            });
        });
    }
});
```

### Phase 5: Performance Benchmarks

Create comprehensive benchmarks comparing our client with curl and quiche-client:

#### Benchmark Categories

1. **Connection Establishment**
   ```typescript
   // tests/e2e/benchmarks/connection.bench.ts
   bench("curl single connection", async () => {
       await curl("https://localhost:4433/");
   });

   bench("zigClient single connection", async () => {
       await zigClient("https://localhost:4433/");
   });

   bench("zigClient pooled connection", async () => {
       await zigClient("https://localhost:4433/", { poolConnections: true });
   });
   ```

2. **Request Throughput**
   ```typescript
   bench("curl 100 sequential requests", async () => {
       for (let i = 0; i < 100; i++) {
           await curl("https://localhost:4433/small");
       }
   });

   bench("zigClient 100 pooled requests", async () => {
       const pool = new ConnectionPool();
       for (let i = 0; i < 100; i++) {
           await zigClient("https://localhost:4433/small", { pool });
       }
   });
   ```

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
