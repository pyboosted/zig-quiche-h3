# WebTransport E2E Test Improvements Plan

## Executive Summary

This document outlines a comprehensive plan to expand end-to-end testing for the WebTransport implementation in zig-quiche-h3. While basic session establishment and datagram echo are currently tested, significant gaps exist in stream testing, error handling, and advanced features.

## Current State Analysis

### What's Currently Working
- ✅ Basic session establishment via Extended CONNECT
- ✅ Datagram echo functionality (`/wt/echo` route)
- ✅ Simple `wt-client` binary for basic connectivity testing
- ✅ Detection of servers without WebTransport support
- ✅ Concurrent session stress testing (H3_STRESS mode)

### What's Implemented but Not Tested

#### Client Implementation (`src/quic/client/webtransport.zig`)
- `openUniStream()` - Create unidirectional streams
- `openBidiStream()` - Create bidirectional streams
- Stream data writing and reading
- Stream closure and error handling
- Datagram queue management
- Session state transitions
- GOAWAY handling

#### Server Implementation (`src/quic/server/webtransport.zig`)
- `openWtUniStream()` - Server-initiated uni streams
- `openWtBidiStream()` - Server-initiated bidi streams
- Stream limit enforcement
- Stream data handlers
- Session cleanup

### Testing Gaps Identified

1. **No stream testing** - Uni/bidi streams are implemented but completely untested
2. **Limited error scenarios** - Only tests missing WebTransport support
3. **No protocol compliance tests** - Varint encoding, capsule processing, etc.
4. **No performance benchmarks** - Throughput, latency, memory usage
5. **No interoperability tests** - Mixed HTTP/3 and WebTransport operations

## Proposed Test Structure

### Directory Organization
```
tests/e2e/
├── webtransport/
│   ├── session.test.ts       # Session lifecycle and management
│   ├── datagrams.test.ts     # Comprehensive datagram testing
│   ├── streams.test.ts       # Uni/bidi stream operations
│   ├── errors.test.ts        # Error handling scenarios
│   ├── interop.test.ts       # Mixed protocol operations
│   └── performance.test.ts   # Benchmarks and stress tests
└── helpers/
    ├── wtClient.ts            # WebTransport client wrapper
    ├── wtSession.ts           # Session management utilities
    └── wtStream.ts            # Stream testing utilities
```

## Detailed Test Plans

### 1. Session Management Tests (`session.test.ts`)

#### Basic Session Lifecycle
```typescript
test("establish and close session cleanly", async () => {
    const session = await wtClient.connect("/wt/echo");
    expect(session.state).toBe("established");

    await session.close(0, "normal closure");
    expect(session.state).toBe("closed");
});
```

#### Session State Transitions
- `connecting` → `established` → `closing` → `closed`
- `connecting` → `failed` (on error)
- Timeout during establishment
- Server-initiated closure

#### Concurrent Sessions
```typescript
test("handle multiple concurrent sessions", async () => {
    const sessions = await Promise.all([
        wtClient.connect("/wt/echo"),
        wtClient.connect("/wt/echo"),
        wtClient.connect("/wt/echo")
    ]);

    // Verify all sessions are independent
    for (const session of sessions) {
        expect(session.sessionId).toBeDefined();
        expect(session.state).toBe("established");
    }
});
```

#### GOAWAY Handling
- Graceful shutdown with GOAWAY
- No new streams after GOAWAY
- Existing streams continue to completion

### 2. Datagram Tests (`datagrams.test.ts`)

#### Enhanced Echo Testing
```typescript
test("echo datagrams with various sizes", async () => {
    const session = await wtClient.connect("/wt/echo");

    // Test different payload sizes
    const sizes = [1, 100, 1200, 65000]; // Up to QUIC datagram limit

    for (const size of sizes) {
        const payload = crypto.randomBytes(size);
        await session.sendDatagram(payload);

        const received = await session.receiveDatagram();
        expect(received).toEqual(payload);
    }
});
```

#### Queue Management
- Send queue overflow handling
- Receive queue overflow handling
- Backpressure mechanisms
- Drop policy verification

#### Performance Under Load
```typescript
test("handle high datagram throughput", async () => {
    const session = await wtClient.connect("/wt/echo");
    const count = 1000;
    const sent = [];

    // Send rapid burst
    for (let i = 0; i < count; i++) {
        const data = `datagram-${i}`;
        sent.push(data);
        await session.sendDatagram(data);
    }

    // Verify most are received (some loss acceptable)
    const received = await session.receiveAllDatagrams(5000);
    expect(received.length).toBeGreaterThan(count * 0.95);
});
```

### 3. Stream Tests (`streams.test.ts`)

#### Unidirectional Streams
```typescript
test("send data over uni stream", async () => {
    const session = await wtClient.connect("/wt/stream-echo");
    const stream = await session.openUniStream();

    const data = "Hello WebTransport!";
    await stream.write(data);
    await stream.close();

    // Server echoes on new stream
    const response = await session.acceptUniStream();
    const received = await response.readAll();
    expect(received).toBe(data);
});
```

#### Bidirectional Streams
```typescript
test("echo over bidi stream", async () => {
    const session = await wtClient.connect("/wt/stream-echo");
    const stream = await session.openBidiStream();

    await stream.write("ping");
    const response = await stream.read();
    expect(response).toBe("ping");

    await stream.write("pong");
    const response2 = await stream.read();
    expect(response2).toBe("pong");
});
```

#### Stream Limits
```typescript
test("enforce stream limits", async () => {
    const session = await wtClient.connect("/wt/limits");

    // Open max allowed streams
    const streams = [];
    for (let i = 0; i < MAX_UNI_STREAMS; i++) {
        streams.push(await session.openUniStream());
    }

    // Next one should fail
    await expect(session.openUniStream()).rejects.toThrow("StreamLimit");
});
```

#### Large Data Transfer
```typescript
test("transfer large file over stream", async () => {
    const session = await wtClient.connect("/wt/stream-echo");
    const stream = await session.openUniStream();

    const size = 10 * 1024 * 1024; // 10MB
    const data = crypto.randomBytes(size);

    await stream.write(data);
    await stream.close();

    const response = await session.acceptUniStream();
    const received = await response.readAll();

    expect(received.length).toBe(size);
    expect(crypto.createHash('sha256').update(received).digest('hex'))
        .toBe(crypto.createHash('sha256').update(data).digest('hex'));
});
```

### 4. Error Handling Tests (`errors.test.ts`)

#### Protocol Errors
```typescript
test("handle invalid session ID", async () => {
    const session = await wtClient.connect("/wt/echo");

    // Manually craft datagram with wrong session ID
    const invalidDatagram = Buffer.concat([
        encodeVarint(999999), // Invalid session ID
        Buffer.from("test")
    ]);

    await expect(session.sendRawDatagram(invalidDatagram))
        .rejects.toThrow("InvalidSessionId");
});
```

#### Resource Exhaustion
```typescript
test("handle resource exhaustion gracefully", async () => {
    const session = await wtClient.connect("/wt/limits");

    // Try to exhaust server resources
    const promises = [];
    for (let i = 0; i < 1000; i++) {
        promises.push(session.openUniStream().catch(() => {}));
    }

    await Promise.all(promises);

    // Session should still be functional
    const testStream = await session.openUniStream();
    await testStream.write("still working");
    expect(testStream.state).toBe("open");
});
```

#### Network Disruption
```typescript
test("recover from temporary network loss", async () => {
    const session = await wtClient.connect("/wt/echo");

    // Simulate network disruption
    await network.disrupt(1000);

    // Should recover and continue working
    await session.sendDatagram("test after disruption");
    const received = await session.receiveDatagram();
    expect(received).toBe("test after disruption");
});
```

### 5. Interoperability Tests (`interop.test.ts`)

#### Mixed HTTP/3 and WebTransport
```typescript
test("HTTP/3 requests alongside WebTransport", async () => {
    const client = createClient();

    // Regular HTTP/3 request
    const httpResponse = await client.get("/api/users");
    expect(httpResponse.status).toBe(200);

    // WebTransport session on same connection
    const session = await client.openWebTransport("/wt/echo");
    await session.sendDatagram("test");

    // Another HTTP/3 request
    const httpResponse2 = await client.get("/api/users/123");
    expect(httpResponse2.status).toBe(200);

    // Verify WebTransport still works
    const received = await session.receiveDatagram();
    expect(received).toBe("test");
});
```

#### H3 Datagrams vs WebTransport Datagrams
```typescript
test("differentiate H3 and WT datagrams", async () => {
    const client = createClient();

    // H3 datagram with flow-id
    await client.sendH3Datagram(flowId, "h3-data");

    // WebTransport datagram with session-id
    const session = await client.openWebTransport("/wt/echo");
    await session.sendDatagram("wt-data");

    // Verify proper routing
    const h3Response = await client.receiveH3Datagram();
    expect(h3Response.flowId).toBe(flowId);
    expect(h3Response.data).toBe("h3-data");

    const wtResponse = await session.receiveDatagram();
    expect(wtResponse).toBe("wt-data");
});
```

## Implementation Requirements

### 1. Enhanced h3-client Binary

Add WebTransport-specific flags to `src/examples/h3_client.zig`:

```zig
const CliArgs = struct {
    // Existing flags...

    // WebTransport additions
    webtransport_session: bool = false,
    wt_uni_stream: bool = false,
    wt_bidi_stream: bool = false,
    wt_stream_data: []const u8 = "",
    wt_stream_count: u32 = 1,
    wt_keep_alive: bool = false,
};
```

### 2. New Server Routes

Add test-specific routes to `src/examples/quic_server_handlers.zig`:

```zig
// Stream echo handler
pub fn wtStreamEchoSessionHandler(
    _: *http.Request,
    session_ptr: *anyopaque
) http.WebTransportError!void {
    const session = QuicServer.WebTransportSession.fromOpaque(session_ptr);

    // Set up stream handlers for echo
    session.setStreamDataHandler(wtEchoStreamData);
    session.setStreamClosedHandler(wtStreamClosed);
}

// Limits testing handler
pub fn wtLimitsSessionHandler(
    _: *http.Request,
    session_ptr: *anyopaque
) http.WebTransportError!void {
    const session = QuicServer.WebTransportSession.fromOpaque(session_ptr);

    // Configure strict limits for testing
    session.setMaxStreams(10, 5); // 10 uni, 5 bidi
    session.setMaxDatagrams(100);
}

// Error injection handler
pub fn wtErrorSessionHandler(
    req: *http.Request,
    session_ptr: *anyopaque
) http.WebTransportError!void {
    const session = QuicServer.WebTransportSession.fromOpaque(session_ptr);

    // Trigger various errors based on query params
    if (req.query("error") == "goaway") {
        session.sendGoAway();
    } else if (req.query("error") == "reset") {
        session.reset(500, "test error");
    }
}
```

### 3. TypeScript Test Helpers

Create `tests/e2e/helpers/wtClient.ts`:

```typescript
export class WebTransportClient {
    private client: H3Client;

    async connect(path: string): Promise<WebTransportSession> {
        const response = await this.client.connect({
            url: `https://127.0.0.1:${port}${path}`,
            webtransport: true,
        });

        return new WebTransportSession(response);
    }
}

export class WebTransportSession {
    async openUniStream(): Promise<WebTransportStream> {
        // Implementation
    }

    async openBidiStream(): Promise<WebTransportStream> {
        // Implementation
    }

    async sendDatagram(data: string | Buffer): Promise<void> {
        // Implementation
    }

    async receiveDatagram(): Promise<Buffer> {
        // Implementation
    }

    async close(code: number, reason: string): Promise<void> {
        // Implementation
    }
}
```

## Testing Strategy

### Phase 1: Foundation (Day 1)
- [ ] Extend h3-client with WebTransport stream support
- [ ] Create wtClient.ts helper wrapper
- [ ] Add `/wt/stream-echo` route to server
- [ ] Write basic session lifecycle tests

### Phase 2: Core Features (Day 2)
- [ ] Implement comprehensive datagram tests
- [ ] Add unidirectional stream tests
- [ ] Add bidirectional stream tests
- [ ] Test concurrent operations

### Phase 3: Error & Edge Cases (Day 3)
- [ ] Error handling scenarios
- [ ] Resource limit testing
- [ ] Network disruption simulation
- [ ] Session cleanup verification

### Phase 4: Performance & Advanced (Day 4)
- [ ] Performance benchmarks
- [ ] Interoperability tests
- [ ] Stress testing under load
- [ ] Memory leak detection

## Success Metrics

### Coverage Goals
- **30+ new test cases** covering all WebTransport features
- **100% coverage** of public API surface
- **All error paths** tested
- **Performance baselines** established

### Quality Metrics
- **< 5% flakiness rate** in CI
- **All tests complete in < 30 seconds**
- **Memory usage stable** under stress
- **Zero memory leaks** detected

### Performance Targets
- **Datagram throughput**: > 10,000 msgs/sec
- **Stream throughput**: > 100 MB/sec
- **Session establishment**: < 50ms locally
- **Concurrent sessions**: > 100 without degradation

## Risk Mitigation

### Potential Risks
1. **Test flakiness** due to timing issues
   - Mitigation: Use proper async/await patterns, add retries

2. **Resource leaks** in test cleanup
   - Mitigation: Ensure proper session closure in afterEach

3. **CI timeout** with stress tests
   - Mitigation: Gate heavy tests behind H3_STRESS flag

4. **Platform differences** (Linux vs macOS)
   - Mitigation: Test on both platforms, handle differences

## Conclusion

This comprehensive test plan will significantly improve confidence in the WebTransport implementation. By systematically testing sessions, streams, datagrams, and error scenarios, we'll ensure the implementation is robust and production-ready. The phased approach allows for incremental progress while maintaining stability.