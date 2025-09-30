# Complete M3 Bun Server TypeScript Bindings

## Current State Analysis

`src/bun/server.ts` (434 lines) already implements:
- ✅ Basic server lifecycle (constructor, start/stop/close)
- ✅ Request/Response with Bun-native objects
- ✅ Streaming response bodies via ReadableStream
- ✅ Headers & trailers support
- ✅ Error handler
- ✅ Thread-safe callbacks

## Critical Architecture Issues Found

### 1. Memory Safety: Arena Lifetime Problem (HIGH PRIORITY)
**Current behavior**: FFI callback is invoked synchronously from `requestHandler` (src/ffi/server.zig:298-314), but Bun's fetch handler uses `queueMicrotask` (src/bun/server.ts:231), making it async. The `RequestState.arena` is deallocated immediately after the handler returns (src/quic/server/h3_core.zig:483, 618, 637, 691), so by the time the microtask executes, all borrowed pointers (method, path, authority, headers, body) are dangling.

**Solution**: Remove queueMicrotask, run synchronously. Bun's JSCallback with `threadsafe: true` already runs on correct thread. The `zig_h3_response_defer_end()` pattern allows async completion after handler returns.

### 2. Streaming Request Bodies Require Callback Wiring (HIGH PRIORITY)
**Current behavior**: Adding `body_ptr/body_len` to ZigRequest only exposes buffered bodies (subject to `max_non_streaming_body_bytes`). True streaming requires the Zig handler to set `state.is_streaming = true` and provide an `on_body_chunk` callback (src/quic/server/h3_core.zig:521-526, src/quic/server/mod.zig:48-51).

**Solution**: Full streaming support via `zig_h3_server_route_streaming()` FFI entry point, per-request state map for ReadableStream controllers, deliver body chunks via JSCallback → controller.enqueue().

### 3. Route Registration Architecture Mismatch (MEDIUM PRIORITY)
**Current behavior**: Routes are registered in `#registerDefaultRoutes()` before server starts (src/bun/server.ts:199-206), and `zig_h3_server_route()` only accepts callbacks at registration time (include/zig_h3.h:189-200). Cannot add DATAGRAM or WT handlers post-facto.

**Solution**: Replace default route registration with explicit `RouteDefinition[]` array. Each route specifies pattern, method, mode, and optional handlers (fetch, datagram, webtransport) at construction time before server starts. Callbacks registered with `zig_h3_server_route()` during initialization.

### 4. Stats Instrumentation Missing (MEDIUM PRIORITY)
**Current behavior**: `QuicServer` has `connections_accepted`, `packets_received`, `packets_sent` (src/quic/server/mod.zig:107-109), but no request counter or start timestamp.

**Solution**: Add `requests_total`, `server_start_time` fields to QuicServer, increment in h3_core when creating RequestState, expose via new `zig_h3_server_stats()` FFI symbol.

## Revised Implementation Plan (Route-First Architecture)

### Phase 0: Refactor to Route Definition API (90-120 min) — FOUNDATION
This fundamentally changes the server initialization to align with Zig's routing architecture.

1. **TypeScript API** (src/bun/server.ts):
   ```typescript
   interface RouteDefinition {
     method: string;
     pattern: string;
     mode?: "buffered" | "streaming";  // Default: buffered
     fetch?: (req: Request, server: H3Server) => Response | Promise<Response>;
     h3Datagram?: (payload: Uint8Array, ctx: H3DatagramContext) => void;
     webtransport?: (ctx: WTContext) => void;
   }

   interface H3ServeOptions {
     // ... existing fields
     routes?: RouteDefinition[];  // Optional, defaults to catch-all
     fetch(req: Request, server: H3Server): Response | Promise<Response>;  // Fallback handler

     // Server-level handlers (not route-specific)
     quicDatagram?: (payload: Uint8Array, ctx: QUICDatagramContext) => void;  // Raw QUIC, connection-scoped
   }

   // Protocol layer distinction:
   // - quicDatagram: Server-level, connection-scoped, arrives before HTTP exchange
   // - h3Datagram: Per-route, request-associated with flow IDs
   // - webtransport: Per-route, session-based with bidirectional streams
   ```

2. **Replace #registerDefaultRoutes()** with #registerRoutes():
   - If `options.routes` provided: iterate and register each
   - Otherwise: register catch-all `GET|POST|PUT|DELETE|... /*` → options.fetch
   - For each route, create up to 3 JSCallbacks (request, datagram, wt)
   - Store route-specific handler references in RouteContext wrapper
   - **Critical**: JSCallback must build complete Request snapshot synchronously (copy all strings, headers, body) before calling async handler

3. **Context wrapper objects** (three protocol layers):
   ```typescript
   interface QUICDatagramContext {
     connectionId: Uint8Array;  // Raw binary QUIC connection ID
     connectionIdHex: string;   // Hex-encoded for logging/comparison
     sendReply(data: Uint8Array): void;  // Wrapper for zig_h3_server_send_quic_datagram
   }

   interface H3DatagramContext {
     streamId: bigint;
     flowId: bigint;
     request: Request;  // Original request that established the flow
     sendReply(data: Uint8Array): void;  // Wrapper for zig_h3_response_send_h3_datagram
   }

   interface WTContext {
     request: Request;
     sessionId: bigint;
     sendDatagram(data: Uint8Array): void;
     close(errorCode?: number, reason?: string): void;
     // TODO: Add uni/bidi stream helpers when zig_h3_wt_stream_* exports land
   }
   ```

4. **Backward compatibility**:
   - Existing test (tests/e2e/ffi/bun_server_basic.test.ts) uses top-level fetch → still works
   - New tests can use `routes: [...]` for per-route control

### Phase 1: Add Streaming Request Body Support (90-120 min)
Now that routes can specify `mode: "streaming"`, implement the infrastructure.

1. **Zig FFI** (src/ffi/server.zig):
   - Add `BodyChunkCallback = ?*const fn(user: ?*anyopaque, chunk: ?[*]const u8, len: usize, finished: u8) callconv(.c) void`
   - Add `zig_h3_server_route_streaming()` export (clones zig_h3_server_route signature + body_chunk_cb param)
   - In streaming variant: set route with `.streaming = true`, wire body chunk callback

2. **Routing builder** (src/routing/dynamic.zig):
   - Verify Builder.add() already accepts `.streaming` field (it does per src/routing/dynamic.zig:120-161)
   - Verify streaming routes populate `on_body_chunk` callback (yes, via requestHandler user_data)

3. **TypeScript streaming bridge** (src/bun/server.ts):
   - Add per-request state map: `#streamingRequests = new Map<string, StreamingRequestState>()`
   - **Key format**: `${connectionIdHex}:${streamId}` to prevent collisions across connections
   - StreamingRequestState = `{ controller: ReadableStreamDefaultController, connectionId: Uint8Array, streamId: bigint }`
   - When route.mode === "streaming":
     - Create JSCallback for body chunks: `(conn_id_ptr, conn_id_len, stream_id, chunk_ptr, len) => { const key = makeKey(connId, streamId); const state = map.get(key); controller.enqueue(...); }`
     - Pass body_chunk_cb to `zig_h3_server_route_streaming()`
     - In request callback: create ReadableStream, store controller in map keyed by composite key
   - **Critical**: Clean up map entry on request completion/error to prevent leaks (use stream close callback)

4. **Header update** (include/zig_h3.h):
   ```c
   // Body chunk callback: NO finished flag (Zig uses separate on_body_complete)
   typedef void (*zig_h3_body_chunk_cb)(
     void *user,
     const uint8_t *conn_id,
     size_t conn_id_len,
     uint64_t stream_id,
     const uint8_t *chunk,
     size_t len
   );

   // Cleanup hooks for resource management
   typedef void (*zig_h3_stream_close_cb)(void *user, uint64_t stream_id, uint8_t aborted);
   typedef void (*zig_h3_connection_close_cb)(void *user, const uint8_t *conn_id, size_t conn_id_len);

   int zig_h3_server_route_streaming(
     zig_h3_server *server,
     const char *method,
     const char *pattern,
     zig_h3_request_cb callback,
     zig_h3_body_chunk_cb body_chunk_cb,  // NEW
     zig_h3_datagram_cb dgram_cb,
     zig_h3_wt_session_cb wt_cb,
     void *user
   );

   // Cleanup hooks registration
   int zig_h3_server_set_stream_close_cb(zig_h3_server *srv, zig_h3_stream_close_cb cb, void *user);
   int zig_h3_server_set_connection_close_cb(zig_h3_server *srv, zig_h3_connection_close_cb cb, void *user);
   ```

   **Note**: Connection ID + stream ID composite key prevents collisions when multiple connections use same stream ID

5. **Test**: Route with `mode: "streaming"`, POST 5MB body in 64KB chunks, verify streaming works

### Phase 1b: Fix Memory Safety for Buffered Mode (30-40 min)
Handle buffered bodies (existing mode) safely.

1. **Refactor request callback** (src/bun/server.ts:218-237):
   - Build complete Request snapshot INSIDE FFI callback: decode + copy all strings, headers, body
   - Call `zig_h3_response_defer_end()` to prevent auto-completion
   - Kick off `this.#handleRequest(snapshot).catch(...)` immediately but DON'T await
   - Return from FFI callback (Zig can now free arena)
   - **Critical**: All ZigRequest pointer reads must complete before return
2. Add `body_ptr/body_len` to ZigRequest struct (src/ffi/server.zig:33-43)
3. Update include/zig_h3.h to match
4. In requestHandler: copy body buffer before invoking callback
5. Update #decodeRequest() to receive pre-copied data (strings, headers, body)
6. Test: POST with 10KB body, verify arrives intact and no use-after-free

**Pattern**:
```typescript
callback(user, reqPtr, respPtr) {
  const snapshot = buildRequestSnapshot(reqPtr);  // Copy everything
  defer_end(respPtr);
  handleRequest(snapshot, respPtr).catch(handleError);  // Fire and forget
  // Return immediately, arena freed
}
```

### Phase 2: Add Stats API (30-40 min)
1. **Zig side** (src/quic/server/mod.zig):
   - Add `requests_total: u64` and `server_start_time_ms: i64` fields
   - Initialize `server_start_time_ms` in `init()` using `std.time.milliTimestamp()`
   - Increment `requests_total` in h3_core when creating RequestState
   - **For active connections**: Compute `self.connections.count()` at query time (don't store counter)
2. **FFI layer** (src/ffi/server.zig):
   - Add `zig_h3_server_stats()` export returning struct with { connections_total, connections_active, requests_total, uptime_ms }
   - Update include/zig_h3.h with typedef
3. **TypeScript** (src/bun/server.ts):
   - Add `getStats()` method reading the struct
   - Map to JS object: `{ connectionsTotal: bigint, connectionsActive: number, requests: bigint, uptimeMs: number }`
4. **Test**: Call getStats() after several requests, verify counts. Test connectionsActive changes as clients connect/disconnect.

### Phase 3A: Raw QUIC Datagram FFI Bridge (60-75 min)
Expose connection-level QUIC DATAGRAMs (server-level handler, not route-specific).

**Key Insight**: QUIC datagrams are connection-scoped and arrive before any HTTP exchange. They cannot be routed by HTTP method/path, so must use a server-level handler in `H3ServeOptions.quicDatagram`.

1. **Zig FFI exports** (src/ffi/server.zig):
   - Add `zig_h3_server_set_quic_datagram_cb(server, cb, user)` that stores callback in `QuicServer.onDatagram`
   - Callback signature: `(user, conn_ptr, payload, payload_len)` — **Pass connection pointer directly, not ID**
   - Add `zig_h3_server_send_quic_datagram(conn_ptr, data, len)` for sending — **Takes connection pointer, not server + ID**
   - **Rationale**: Zig already has ConnectionTable for ID→Connection* mapping; no need for duplicate registry in FFI layer
   - **Cleanup hooks**: Register `zig_h3_connection_close_cb` to clean up any Bun-side connection state when connections close

2. **TypeScript wrapper** (src/bun/server.ts):
   ```typescript
   class QUICDatagramContext {
     #symbols: ServerSymbols;
     #connPtr: Pointer;  // Store connection pointer, not server + ID
     readonly connectionId: Uint8Array;  // Raw binary
     readonly connectionIdHex: string;   // Hex for logging

     constructor(symbols, connPtr: Pointer, connectionId: Uint8Array) {
       this.#symbols = symbols;
       this.#connPtr = connPtr;
       this.connectionId = connectionId;
       // Convert to hex for logging/comparison (binary-safe)
       this.connectionIdHex = Array.from(connectionId)
         .map(b => b.toString(16).padStart(2, '0'))
         .join('');
     }

     sendReply(data: Uint8Array): void {
       check(
         this.#symbols.zig_h3_server_send_quic_datagram(
           this.#connPtr,  // Use stored connection pointer
           ptr(data),
           data.length
         ),
         "QUICDatagramContext.sendReply"
       );
     }
   }
   ```

3. **Wire server-level callback** in constructor:
   - If `options.quicDatagram` provided:
     - Create JSCallback wrapping `options.quicDatagram(payload, ctx)`
     - Call `zig_h3_server_set_quic_datagram_cb(server, callback, user)` once
   - **Note**: Single server-level handler, not per-route (QUIC datagrams are connection-scoped)

4. **Register cleanup hooks** (src/bun/server.ts):
   - Register `zig_h3_connection_close_cb` in constructor to clean up any Bun-side connection state
   - Register `zig_h3_stream_close_cb` in constructor to clean up streaming request map entries
   - **Critical**: Prevents memory leaks when connections/streams close unexpectedly
   - Callback implementation:
     ```typescript
     const streamCloseCallback = JSCallback((user, streamId, aborted) => {
       // Clean up #streamingRequests entries for this stream across all connections
       for (const [key, state] of this.#streamingRequests) {
         if (state.streamId === streamId) {
           if (aborted) state.controller.error(new Error("Stream aborted"));
           else state.controller.close();
           this.#streamingRequests.delete(key);
         }
       }
     }, { threadsafe: true });
     ```

5. **Test**: Set `options.quicDatagram` handler, use native quic_dgram_echo client to send raw bytes, verify echo

### Phase 3B: H3 DATAGRAM Per-Route Handlers (30-40 min)
HTTP/3 DATAGRAMs are request-associated with flow IDs (src/quic/server/datagram.zig).

1. **Implement H3DatagramContext** (src/bun/server.ts):
   ```typescript
   class H3DatagramContext {
     #symbols: ServerSymbols;
     #responsePtr: Pointer;

     constructor(
       readonly streamId: bigint,
       readonly flowId: bigint,
       readonly request: Request,
       symbols: ServerSymbols,
       responsePtr: Pointer
     ) {
       this.#symbols = symbols;
       this.#responsePtr = responsePtr;
     }

     sendReply(data: Uint8Array): void {
       check(
         this.#symbols.zig_h3_response_send_h3_datagram(
           this.#responsePtr,
           ptr(data),
           data.length
         ),
         "sendReply"
       );
     }
   }

   class WTContext {
     #symbols: ServerSymbols;
     #sessionPtr: Pointer;

     constructor(
       readonly request: Request,
       readonly sessionId: bigint,
       symbols: ServerSymbols,
       sessionPtr: Pointer
     ) {
       this.#symbols = symbols;
       this.#sessionPtr = sessionPtr;
     }

     sendDatagram(data: Uint8Array): void {
       check(
         this.#symbols.zig_h3_wt_send_datagram(
           this.#sessionPtr,
           ptr(data),
           data.length
         ),
         "WTContext.sendDatagram"
       );
     }

     close(errorCode: number = 0, reason: string = ""): void {
       const reasonBuf = new TextEncoder().encode(reason);
       check(
         this.#symbols.zig_h3_wt_close(
           this.#sessionPtr,
           errorCode,
           ptr(reasonBuf),
           reasonBuf.length
         ),
         "WTContext.close"
       );
     }
   }
   ```

2. **Wire H3 DATAGRAM callback** in #registerRoutes():
   - If route.h3Datagram defined:
     - Create JSCallback wrapping route.h3Datagram(data, ctx)
     - Build H3DatagramContext from ZigRequest + flow_id + response pointer
     - Pass callback to zig_h3_server_route() as dgram_cb param
   - **Note**: Zig signature is `(req, resp, data, data_len)` per src/ffi/server.zig:56
   - **Critical**: Call `QuicServer.incrementH3DatagramSent()` when sending from Bun (matches src/quic/server/datagram.zig stats)

3. **Test**: Route with h3Datagram handler, POST to /h3dgram/echo with flow ID, verify echo

### Phase 3C: WebTransport Session API (40-50 min)
WebTransport provides sessions with bidirectional streams and datagrams.

1. **Implement WTContext** (already done in Phase 3B setup):
   - sendDatagram() wraps `zig_h3_wt_send_datagram`
   - close() wraps `zig_h3_wt_close`
   - TODO: Add stream helpers once `zig_h3_wt_stream_open_uni/bidi` exports land

2. **Wire WT callback** in #registerRoutes():
   - If route.webtransport defined:
     - Create JSCallback wrapping route.webtransport(session, ctx)
     - Build WTContext from ZigRequest + session pointer
     - Pass callback to zig_h3_server_route() as wt_cb param

4. **Test**: Route with webtransport handler, CONNECT to /wt/session, send datagram, verify received

**Note**: WebTransport stream helpers (uni/bidi) deferred until `QuicServer.WTApi` stream exports are available in FFI layer.

### Phase 4: Lifecycle Extensions (20-30 min)
1. **Document** reload() not needed (server is stateless, restart to pick up route changes)
2. **Add force flag** to stop():
   - Update FFI signature: `zig_h3_server_stop(ptr, force: u8)`
   - TypeScript signature: `stop(force?: boolean): void` (defaults to false)
   - Implement forceful connection termination in Zig (close all streams immediately)
   - Backward compatible: existing `server.stop()` calls continue to work
3. **Add tests** for Bun.file() and async iterator response bodies (likely already work)
4. **Add JSDoc** for all public H3Server methods and route interfaces

### Phase 5: Error Handling & Documentation (30-40 min)

#### 4-Tier Error Handling Strategy
Implement comprehensive error handling to avoid crash-on-throw issues:

1. **Tier 1: Configuration Errors** → Throw during construction
   - Invalid port, missing cert/key files, malformed route patterns
   - **Rationale**: Fail fast before server starts; user must fix config
   - **Example**: `throw new TypeError("Invalid route pattern: missing leading /")`

2. **Tier 2: Request Handler Errors** → Return error Response
   - Handler throws exception, body parsing fails, validation errors
   - **Rationale**: Isolate per-request failures; log and return 500
   - **Example**:
     ```typescript
     try {
       return await handler(req);
     } catch (err) {
       console.error("Handler error:", err);
       return new Response("Internal Server Error", { status: 500 });
     }
     ```

3. **Tier 3: Protocol-Level Errors** → Log and drop
   - Malformed QUIC packets, invalid HTTP/3 frames, stream state violations
   - **Rationale**: Best-effort networking; these are transient and recoverable
   - **Example**: `console.warn("Protocol error:", err); // Continue serving`

4. **Tier 4: Stream-Level Errors** → Send stream reset
   - Client aborts stream, flow control violations, timeout
   - **Rationale**: Graceful degradation; notify peer and clean up resources
   - **Example**: `quic_conn.streamShutdown(streamId, H3_INTERNAL_ERROR)`

#### Additional Polish
5. Create src/bun/internal/conversions.ts for shared helpers (header encoding, buffer copies)
6. Refactor duplicate code between server.ts and client.ts
7. Add comprehensive JSDoc comments for all public APIs
8. Document limitations (streaming request body backpressure, max chunk sizes)

### Phase 6: Comprehensive Testing (50-60 min)
1. **Buffered mode tests**:
   - POST with small body (1KB JSON)
   - POST with large body (512KB)
   - POST with empty body
   - POST exceeding 1MB (should get 413)
2. **Streaming mode tests**:
   - POST with 5MB body in chunks, verify all chunks received
   - Concurrent streaming uploads (3 parallel 2MB posts)
3. **Protocol layer tests** (QUIC → H3 → WT):
   - **QUIC datagram**: Use native quic_dgram_echo client, send raw bytes, verify echo
   - **H3 datagram**: POST to /h3dgram/echo with flow ID, send via streaming request, verify echo
   - **WebTransport**: CONNECT to /wt/session, send datagram via session, verify received
4. **Route-specific tests**:
   - Multiple routes with different modes
   - Multiple protocol layers on same server
   - Fallback to default fetch handler
5. **Error handling**:
   - Handler throws error → error handler invoked
   - Invalid route pattern → server initialization fails
6. **Lifecycle**:
   - Graceful shutdown (inflight requests complete)
   - Force shutdown (connections dropped)
7. **Stress variant** (H3_STRESS=1):
   - 100+ concurrent requests
   - 10 streaming uploads in parallel
   - QUIC datagram burst (1000+ raw packets)

## Total Estimated Time: 22-31 hours

### Breakdown by Phase
- Phase 0: 90-120 min (route refactor)
- Phase 1: 240-360 min (streaming infrastructure + FFI wiring + state management)
- Phase 1b: 30-40 min (buffered mode safety)
- Phase 2: 30-40 min (stats)
- Phase 3A: 60-75 min (QUIC datagram + cleanup hooks)
- Phase 3B: 30-40 min (H3 datagram)
- Phase 3C: 40-50 min (WebTransport)
- Phase 4: 20-30 min (lifecycle)
- Phase 5: 30-40 min (error handling + polish)
- Phase 6: 360-480 min (comprehensive testing + integration tests + examples)

### Rationale for Revised Estimate
Original 6-7h estimate did not account for:
- **Streaming request bodies**: Full FFI integration with ReadableStream controllers (4-6h)
- **Connection pooling implications**: State management for cleanup hooks (2-3h)
- **Error handling polish**: 4-tier strategy implementation (2-3h)
- **Response backpressure**: Managing flow control when Bun ReadableStream is slow (3-4h)
- **TSDoc comments**: Comprehensive API documentation (3-4h)
- **Integration tests**: Protocol layer interop testing (6-8h)
- **Examples**: Reference implementations for all three protocol layers (2-3h)

### Confidence Level
- **Lower bound (22h)**: Optimistic; assumes smooth FFI integration, no major bugs in cleanup hooks
- **Upper bound (31h)**: Realistic; accounts for debugging stream state issues, testing edge cases, documentation polish

**Note**: Time estimate reflects production-ready implementation with full error handling, cleanup hooks, and comprehensive testing

## Success Criteria
- [ ] Routes can be defined with explicit patterns, methods, and modes
- [ ] Buffered mode: bodies up to 1MB copied safely to JS
- [ ] Streaming mode: bodies of any size delivered via ReadableStream
- [ ] Request data is safely copied to JS memory (no dangling pointers)
- [ ] QUIC datagram handlers work (raw connection-level)
- [ ] H3 datagram handlers work (flow ID-based)
- [ ] WebTransport handlers work (session-based)
- [ ] All three protocol layers can coexist on same server
- [ ] stop(force=true) forcefully terminates connections
- [ ] getStats() returns runtime metrics (connections, requests, uptime)
- [ ] Bun.file() responses work (tested)
- [ ] Async iterators for response bodies work (tested)
- [ ] Backward compatibility: existing tests still pass
- [ ] All new tests pass including all three protocol layers
- [ ] M3 checklist in docs/bun-ffi-plan.md is complete

## Key Design Decisions

### Route-First Architecture (NEW)
**Decision**: Replace default route registration with explicit route definitions before server starts.

**Rationale**:
- Aligns with Zig's registration-time callback binding (src/ffi/server.zig:338-375)
- Enables per-route configuration (streaming, DATAGRAM, WT)
- Provides type-safe context objects for handlers
- Maintains backward compatibility via fallback to top-level fetch

**API**:
```typescript
createH3Server({
  routes: [
    { method: "POST", pattern: "/api/upload", mode: "streaming", fetch: handleUpload },
    { method: "POST", pattern: "/h3dgram/echo", datagram: handleDatagram },
    { method: "CONNECT", pattern: "/wt/session", webtransport: handleWT }
  ],
  fetch: defaultHandler  // Fallback for unmatched routes
})
```

### Request Body Strategy (REVISED - Now Supports Streaming!)
**Decision**: Support both buffered and streaming modes via per-route `mode` flag.

**Rationale**:
- Route-first architecture makes it natural to specify mode per-route
- `zig_h3_server_route_streaming()` FFI entry point enables streaming with minimal changes
- Zig side already has `on_body_chunk` infrastructure (src/quic/server/mod.zig:48-51)
- JS ReadableStream provides backpressure-aware streaming
- Buffered mode remains default for simplicity

**Implementation**:
- **Buffered (default)**: Body collected up to 1MB, copied to JS Uint8Array, passed in Request
- **Streaming**: Body chunks delivered via JSCallback → ReadableStream controller, no size limit

### Stats API Design (REVISED)
**Decision**: Add minimal instrumentation to QuicServer, expose via FFI.

**Rationale**: Existing counters track packets but not requests. Adding request_total counter and start timestamp enables basic observability without overhead.

```typescript
interface ServerStats {
  connectionsTotal: bigint;   // cumulative accepted connections (connections_accepted)
  connectionsActive: number;  // current connection count (self.connections.count())
  requests: bigint;           // lifetime request count (NEW: requests_total)
  uptimeMs: number;           // milliseconds since start (NEW: computed from server_start_time_ms)
}
```

**Note**: Clarified that connectionsTotal is cumulative, connectionsActive is current count.

### DATAGRAM/WebTransport Integration (REVISED - Per-Route!)
**Decision**: DATAGRAM and WebTransport handlers are properties of individual routes, not global options.

**Rationale**:
- Route-first architecture allows per-route callbacks
- Each route can have its own DATAGRAM or WT handler
- Callbacks passed at registration time align with Zig FFI architecture
- Context objects provide type-safe access to flow IDs, session handles

**API**:
```typescript
interface RouteDefinition {
  pattern: string;
  method: string;
  h3Datagram?(payload: Uint8Array, ctx: H3DatagramContext): void;
  webtransport?(ctx: WTContext): void;
}

createH3Server({
  // Server-level: raw QUIC datagrams (connection-scoped, no HTTP context)
  quicDatagram: (payload, ctx) => {
    console.log(`QUIC datagram from connection ${ctx.connectionIdHex}`);
    ctx.sendReply(payload);  // Echo back at QUIC level
  },

  // Route-level: HTTP/3 and WebTransport (request-associated)
  routes: [
    {
      method: "POST",
      pattern: "/h3dgram/echo",
      h3Datagram: (payload, ctx) => {
        // HTTP/3 DATAGRAM with flow ID
        console.log(`H3 datagram on stream ${ctx.streamId}, flow ${ctx.flowId}`);
        ctx.sendReply(payload);  // Echo back using response handle
      }
    },
    {
      method: "CONNECT",
      pattern: "/wt/:id",
      webtransport: (ctx) => {
        // WebTransport session
        ctx.sendDatagram(new TextEncoder().encode("welcome"));
        // Session continues, can send more datagrams/close later
      }
    }
  ],

  fetch: (req) => new Response("Hello")  // Fallback
})
```

## Testing Requirements (M4 Alignment)

### Core Functionality Tests
- ✅ Basic GET requests (existing)
- ✅ Streaming responses (existing)
- ✅ JSON payloads (existing)
- [ ] POST with body
- [ ] PUT with body
- [ ] Request headers preservation
- [ ] Trailers handling

### Advanced Tests
- [ ] Bun.file() responses
- [ ] Async iterator responses
- [ ] H3 DATAGRAM echo
- [ ] WebTransport session lifecycle
- [ ] Error handler invocation
- [ ] Stats API accuracy

### Negative Tests
- [ ] Oversized request body
- [ ] Handler throws error
- [ ] Invalid response status
- [ ] Connection drop during streaming

### Stress Tests (H3_STRESS=1)
- [ ] 100+ concurrent requests
- [ ] Large file downloads (100MB+)
- [ ] Rapid connect/disconnect cycles
- [ ] DATAGRAM burst (1000+ messages)

## Implementation Priority & Risks

### Must-Have for M3 (Blocking)
1. **Phase 0: Route-First Refactor** - Foundation for all other features, breaks existing API temporarily
2. **Phase 1b: Buffered Mode Safety** - Memory safety critical for any production use
3. **Phase 6: Core Tests** - Validate buffered mode works, ensure backward compatibility

### Should-Have for M3 (High Value)
4. **Phase 1: Streaming Support** - Major feature, completes request body handling
5. **Phase 2: Stats API** - Observability is listed in M3 requirements
6. **Phase 3A-C: Protocol Layer Exposure** - QUIC, H3, WT datagrams enable real-time use cases

### Nice-to-Have for M3 (Polish)
7. **Phase 4: Lifecycle Extensions** - stop(force) aligns with Bun.serve API but not critical
8. **Phase 5: Polish** - Incremental improvements, not blockers

### Risks

**High**: Phase 0 route refactor may break existing tests
- **Mitigation**: Implement backward compatibility first (default catch-all route)
- **Fallback**: Feature-flag the new API, keep old registration path

**High**: Phase 1 streaming body chunks may leak memory if controller not cleaned up
- **Mitigation**: Store controllers weakly, clean up on request completion
- **Fallback**: Only support buffered mode, defer streaming to M5

**Medium**: Stats counter placement may impact hot path performance
- **Mitigation**: Use atomic increment only, no locks
- **Fallback**: Make stats opt-in via config flag

**Low**: DATAGRAM/WT callback threading may deadlock
- **Mitigation**: Both callbacks already use threadsafe:true pattern from M1
- **Fallback**: Queue events to main thread via channel

### Implementation Order

**Complete M3 Implementation** (6-7 hours):
- Phase 0 → Phase 1 → Phase 1b → Phase 2 → Phase 3A → Phase 3B → Phase 3C → Phase 4 → Phase 5 → Phase 6
- Delivers: Full feature set including streaming, stats, all three protocol layers (QUIC, H3, WT)

**Rationale**:
- Synchronous execution eliminates lifetime complexity
- Full streaming unlocks production use cases (large uploads, proxies, file processing)
- Three-layer protocol exposure enables real-time applications (gaming, video, collaborative editing)
- Complete implementation justified by architectural cleanup

## Out of Scope for M3

- Connection pooling docs (deferred from M2)
- **npm package publishing** (moved to M6)
- Benchmarking (M5)
- Qlog controls exposure (M5)
- Advanced routing (regex, middleware) - current pattern matching sufficient
- **Windows support** - Server will most likely never have Windows support; focus on macOS/Linux

## M6: npm Package Publishing (Future Milestone)

**Scope**: Distribution and versioning infrastructure
- Package.json configuration (name, version, exports, types)
- TypeScript type definitions (.d.ts generation)
- Binary distribution strategy (prebuild-install, @oven/bun, or dynamic download)
- Cross-platform build automation (macOS/Linux)
- CI/CD pipeline for automated releases
- Documentation for consumers (README, API reference)
- Version compatibility matrix (Bun versions, Zig versions)
- CHANGELOG maintenance

**Rationale**: Publishing is a distinct concern from implementation. M3 should focus on feature completeness and API stability; M6 can address packaging once APIs are frozen and thoroughly tested.

**Estimated Time**: 12-16 hours (includes CI setup, cross-platform testing, documentation)