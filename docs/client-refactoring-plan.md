# QuicClient Refactoring Plan

## Executive Summary

The `QuicClient` implementation in `src/quic/client/mod.zig` has grown into a 2000+ line monolithic module that is becoming increasingly difficult to maintain and extend. This document proposes a refactoring strategy to break down this god object into smaller, focused modules following the same facade pattern successfully used in the server implementation.

## Current State Analysis

### Problems with the Monolithic Design

1. **Size and Complexity**: At 2000+ lines, the file is too large to navigate efficiently
2. **Mixed Concerns**: Connection management, HTTP/3 processing, WebTransport, datagrams, and request handling are all intertwined
3. **Testing Difficulty**: Testing individual features requires instantiating the entire client
4. **Maintenance Burden**: Bug fixes and feature additions affect unrelated code paths
5. **Code Duplication**: Similar patterns (like datagram handling) can't be easily shared with the server
6. **Poor Discoverability**: New developers struggle to understand where specific functionality lives

### Current Responsibilities

The `QuicClient` struct currently handles:
- **Connection Management** (lines 613-734, 759-824)
  - DNS resolution
  - Socket setup and binding
  - QUIC handshake
  - Connection state tracking
  - Reconnection logic

- **HTTP/3 Event Processing** (lines 1597-1651, 1653-1745, 1747-1826, 1828-1907)
  - Headers processing
  - Data streaming
  - Stream completion
  - GOAWAY handling
  - Reset handling

- **WebTransport** (lines 967-1078 and scattered)
  - Session establishment via Extended CONNECT
  - Capsule processing
  - Stream management
  - Datagram routing

- **Datagram Management** (lines 867-909, 939-965, 1653-1703, 1705-1745)
  - Plain QUIC datagrams
  - H3 datagrams with flow-id
  - WebTransport datagrams
  - Send/receive queuing

- **Request/Response Lifecycle** (lines 139-227, 740-865, 1080-1153)
  - FetchState management
  - Request body providers
  - Response callbacks
  - Retry logic

- **Timer Management** (lines 1554-1595)
  - Timeout handling
  - Connect timeouts
  - Event loop integration

- **Logging Infrastructure** (lines 1406-1428)
  - Qlog setup
  - Keylog management
  - Debug logging

## Successful Server Architecture

The server implementation demonstrates a clean separation of concerns using a facade pattern:

```zig
// Server's modular architecture
pub const QuicServer = struct {
    // Facade imports
    const DatagramFeature = @import("datagram.zig");
    const D = DatagramFeature.Impl(@This());
    const H3Core = @import("h3_core.zig");
    const H3 = H3Core.Impl(@This());
    const WTCore = @import("webtransport.zig");
    const WT = WTCore.Impl(@This());

    // Delegated methods
    pub fn sendDatagram(self: *QuicServer, conn: *connection.Connection, data: []const u8) !void {
        return D.sendDatagram(self, conn, data);
    }

    pub fn processH3(self: *QuicServer, conn: *connection.Connection) !void {
        return H3.processH3(self, conn);
    }
};
```

### Benefits Observed in Server

1. **Clear Module Boundaries**: Each file has a single, well-defined purpose
2. **Testability**: Individual facades can be tested in isolation
3. **Maintainability**: Changes to H3 processing don't affect datagram code
4. **Reusability**: Common patterns are easily shared
5. **Performance**: No runtime overhead due to compile-time generic instantiation

## Proposed Client Architecture

### Module Structure

```
src/quic/client/
├── mod.zig                    # Main client struct (500-600 lines)
├── config.zig                 # Already exists
├── webtransport.zig          # Already exists (standalone)
├── h3_events.zig             # NEW: HTTP/3 event processing
├── datagram.zig              # NEW: Datagram management
├── fetch.zig                 # NEW: Request/response lifecycle
├── connection.zig            # NEW: Connection lifecycle
├── timers.zig                # NEW: Timer management
├── webtransport_facade.zig  # NEW: WebTransport integration
└── logging.zig               # NEW: Logging utilities
```

### Detailed Module Breakdown

#### 1. `h3_events.zig` - HTTP/3 Event Processing
```zig
pub fn Impl(comptime C: type) type {
    return struct {
        pub fn processH3Events(client: *C) void {
            // Poll H3 connection for events
            // Dispatch to appropriate handlers
        }

        pub fn onH3Headers(client: *C, stream_id: u64, event: *quiche.c.quiche_h3_event) void {
            // Process headers/trailers
            // Update FetchState
            // Emit callbacks
        }

        pub fn onH3Data(client: *C, stream_id: u64) void {
            // Read body data
            // Handle WebTransport capsules
            // Accumulate response body
        }

        pub fn onH3Finished(client: *C, stream_id: u64) void {
            // Mark stream as complete
            // Trigger awaiting operations
        }

        pub fn onH3GoAway(client: *C, last_stream_id: u64) void {
            // Handle graceful shutdown
            // Cancel affected requests
        }

        pub fn onH3Reset(client: *C, stream_id: u64) void {
            // Handle stream reset
            // Clean up state
        }
    };
}
```

#### 2. `datagram.zig` - Unified Datagram Management
```zig
pub fn Impl(comptime C: type) type {
    return struct {
        pub fn sendH3Datagram(client: *C, stream_id: u64, payload: []const u8) !void {
            // Send H3 datagram with flow-id
        }

        pub fn sendQuicDatagram(client: *C, payload: []const u8) !void {
            // Send plain QUIC datagram
        }

        pub fn processDatagrams(client: *C) void {
            // Read available datagrams
            // Route H3 vs plain QUIC
            // Dispatch to handlers
        }

        pub fn processH3Datagram(client: *C, payload: []const u8) !bool {
            // Decode flow-id
            // Route to WebTransport session or request
        }

        pub fn onQuicDatagram(client: *C, cb: DatagramCallback, user: ?*anyopaque) void {
            // Register plain QUIC datagram handler
        }
    };
}
```

#### 3. `fetch.zig` - Request/Response Lifecycle
```zig
pub fn Impl(comptime C: type) type {
    return struct {
        pub fn startRequest(client: *C, allocator: Allocator, options: FetchOptions) !FetchHandle {
            // Create FetchState
            // Send HTTP/3 request
            // Handle body providers
        }

        pub fn finalizeFetch(client: *C, stream_id: u64) !FetchResponse {
            // Collect response data
            // Clean up state
            // Return response
        }

        pub fn fetchWithRetry(client: *C, allocator: Allocator, options: FetchOptions, max_retries: u32) !FetchResponse {
            // Retry logic for transient failures
        }

        pub fn cancelFetch(client: *C, stream_id: u64, err: ClientError) void {
            // Cancel in-flight request
            // Clean up resources
        }

        fn trySendBody(client: *C, stream_id: u64, state: *FetchState) !bool {
            // Send request body chunks
            // Handle backpressure
        }

        fn loadNextBodyChunk(client: *C, state: *FetchState) !void {
            // Pull from body provider
        }
    };
}
```

#### 4. `connection.zig` - Connection Lifecycle
```zig
pub fn Impl(comptime C: type) type {
    return struct {
        pub fn connect(client: *C, endpoint: ServerEndpoint) !void {
            // DNS resolution
            // Socket setup
            // QUIC handshake
            // H3 initialization
        }

        pub fn reconnect(client: *C) !void {
            // Close existing connection
            // Re-establish with saved endpoint
        }

        pub fn isEstablished(client: *const C) bool {
            // Check connection state
        }

        fn handleReadable(client: *C, fd: posix.socket_t) !void {
            // Process incoming packets
            // Update connection state
        }

        fn flushSend(client: *C) !void {
            // Send queued packets
        }

        fn checkHandshakeState(client: *C) void {
            // Monitor handshake progress
            // Transition states
        }
    };
}
```

#### 5. `timers.zig` - Timer Management
```zig
pub fn Impl(comptime C: type) type {
    return struct {
        pub fn updateTimeout(client: *C) void {
            // Update QUIC timeout timer
        }

        pub fn startConnectTimer(client: *C) void {
            // Start connection timeout
        }

        pub fn stopConnectTimer(client: *C) void {
            // Cancel connection timeout
        }

        fn onQuicTimeout(user_data: *anyopaque) void {
            // Handle QUIC timeout event
        }

        fn onConnectTimeout(user_data: *anyopaque) void {
            // Handle connection timeout
        }
    };
}
```

#### 6. `webtransport_facade.zig` - WebTransport Integration
```zig
pub fn Impl(comptime C: type) type {
    return struct {
        pub fn openWebTransport(client: *C, path: []const u8) !*WebTransportSession {
            // Send Extended CONNECT
            // Create session tracking
        }

        pub fn cleanupWebTransportSession(client: *C, stream_id: u64) void {
            // Clean up session resources
            // Remove from tracking maps
        }

        pub fn markWebTransportSessionClosed(client: *C, stream_id: u64) void {
            // Mark session as closed
            // Keep for user cleanup
        }

        fn processWtCapsules(client: *C, session: *WebTransportSession, data: []const u8) !void {
            // Process WebTransport capsules
            // Update session state
        }
    };
}
```

### Main Client Structure After Refactoring

```zig
pub const QuicClient = struct {
    // Core state
    allocator: std.mem.Allocator,
    config: ClientConfig,
    quiche_config: quiche.Config,
    h3_config: H3Config,
    event_loop: *EventLoop,

    // Connection state
    socket: ?udp.UdpSocket = null,
    conn: ?quiche.Connection = null,
    h3_conn: ?H3Connection = null,
    state: State = .idle,

    // Tracking maps
    requests: AutoHashMap(u64, *FetchState),
    wt_sessions: AutoHashMap(u64, *WebTransportSession),
    wt_streams: AutoHashMap(u64, *WebTransportSession.Stream),

    // Statistics
    datagram_stats: DatagramStats = .{},
    wt_capsules_sent: CapsuleCounters = .{},
    wt_capsules_received: CapsuleCounters = .{},

    // Facades
    const H3Events = @import("h3_events.zig");
    const H3 = H3Events.Impl(@This());
    const DatagramMgmt = @import("datagram.zig");
    const Dgram = DatagramMgmt.Impl(@This());
    const FetchMgmt = @import("fetch.zig");
    const Fetch = FetchMgmt.Impl(@This());
    const ConnMgmt = @import("connection.zig");
    const Conn = ConnMgmt.Impl(@This());
    const TimerMgmt = @import("timers.zig");
    const Timer = TimerMgmt.Impl(@This());
    const WTFacade = @import("webtransport_facade.zig");
    const WT = WTFacade.Impl(@This());

    // Public API delegates to facades
    pub fn connect(self: *QuicClient, endpoint: ServerEndpoint) ClientError!void {
        return Conn.connect(self, endpoint);
    }

    pub fn fetch(self: *QuicClient, allocator: Allocator, path: []const u8) ClientError!FetchResponse {
        return Fetch.fetch(self, allocator, path);
    }

    pub fn sendH3Datagram(self: *QuicClient, stream_id: u64, payload: []const u8) ClientError!void {
        return Dgram.sendH3Datagram(self, stream_id, payload);
    }

    pub fn openWebTransport(self: *QuicClient, path: []const u8) ClientError!*WebTransportSession {
        return WT.openWebTransport(self, path);
    }

    // Internal coordination methods
    fn afterQuicProgress(self: *QuicClient) void {
        Timer.updateTimeout(self);
        Fetch.sendPendingBodies(self);
        H3.processWritableStreams(self);
        WT.flushPendingDatagrams(self);
        Conn.checkHandshakeState(self);
        H3.processH3Events(self);
        Dgram.processDatagrams(self);
    }
};
```

## Implementation Plan

### Phase 1: Preparation (No Breaking Changes)
- [ ] **Create facade files** with stub implementations
  - [ ] Create `src/quic/client/h3_events.zig`
  - [ ] Create `src/quic/client/datagram.zig`
  - [ ] Create `src/quic/client/fetch.zig`
  - [ ] Create `src/quic/client/connection.zig`
  - [ ] Create `src/quic/client/timers.zig`
  - [ ] Create `src/quic/client/webtransport_facade.zig`
  - [ ] Create `src/quic/client/logging.zig`
- [ ] **Add facade imports** to main client
- [ ] **Write comprehensive tests** for current functionality
  - [ ] Test connection establishment
  - [ ] Test HTTP/3 request/response
  - [ ] Test WebTransport sessions
  - [ ] Test datagram handling
  - [ ] Test reconnection logic
- [ ] **Document current behavior** for regression testing

### Phase 2: Incremental Migration
#### 2.1 Leaf Functionality (timers, logging)
- [ ] **Extract timer management**
  - [ ] Move `onQuicTimeout` callback
  - [ ] Move `onConnectTimeout` callback
  - [ ] Move `updateTimeout` method
  - [ ] Move `stopConnectTimer` method
  - [ ] Move `stopTimeoutTimer` method
- [ ] **Extract logging setup**
  - [ ] Move `setupQlog` method
  - [ ] Move keylog initialization
  - [ ] Move debug logging configuration

#### 2.2 Datagram Handling
- [ ] **Extract datagram core**
  - [ ] Move `sendH3Datagram` method
  - [ ] Move `sendQuicDatagram` method
  - [ ] Move `processDatagrams` method
  - [ ] Move `processH3Datagram` method
- [ ] **Extract datagram callbacks**
  - [ ] Move `onQuicDatagram` registration
  - [ ] Move datagram statistics tracking

#### 2.3 H3 Event Processing
- [ ] **Extract event handlers**
  - [ ] Move `processH3Events` method
  - [ ] Move `onH3Headers` method
  - [ ] Move `onH3Data` method
  - [ ] Move `onH3Finished` method
  - [ ] Move `onH3GoAway` method
  - [ ] Move `onH3Reset` method
- [ ] **Extract stream management**
  - [ ] Move `processWritableStreams` logic
  - [ ] Move stream state tracking

#### 2.4 Fetch Lifecycle
- [ ] **Extract request initiation**
  - [ ] Move `startRequest` method
  - [ ] Move `prepareRequestHeaders` method
  - [ ] Move `FetchState` struct and methods
  - [ ] Move `FetchHandle` struct and methods
- [ ] **Extract response handling**
  - [ ] Move `finalizeFetch` method
  - [ ] Move `fetchWithOptions` method
  - [ ] Move `fetchWithRetry` method
- [ ] **Extract body management**
  - [ ] Move `trySendBody` method
  - [ ] Move `loadNextBodyChunk` method
  - [ ] Move `sendPendingBodies` method
  - [ ] Move body provider logic

#### 2.5 Connection Management
- [ ] **Extract connection lifecycle**
  - [ ] Move `connect` method
  - [ ] Move `reconnect` method
  - [ ] Move `isEstablished` method
  - [ ] Move DNS resolution logic
  - [ ] Move socket setup logic
- [ ] **Extract packet processing**
  - [ ] Move `handleReadable` method
  - [ ] Move `flushSend` method
  - [ ] Move `afterQuicProgress` coordination
- [ ] **Extract handshake logic**
  - [ ] Move `checkHandshakeState` method
  - [ ] Move handshake error handling
  - [ ] Move H3 connection initialization

#### 2.6 WebTransport Facade
- [ ] **Wire up WebTransport integration**
  - [ ] Move `openWebTransport` method
  - [ ] Move `cleanupWebTransportSession` method
  - [ ] Move `markWebTransportSessionClosed` method
- [ ] **Extract capsule handling**
  - [ ] Move capsule send logic
  - [ ] Move capsule receive routing
  - [ ] Move capsule statistics

### Phase 3: Cleanup and Optimization
- [ ] **Code cleanup**
  - [ ] Remove dead code from main client
  - [ ] Remove redundant imports
  - [ ] Consolidate error handling
- [ ] **API optimization**
  - [ ] Review internal APIs between facades
  - [ ] Optimize data passing between modules
  - [ ] Reduce unnecessary allocations
- [ ] **Testing improvements**
  - [ ] Add unit tests for each facade
  - [ ] Add integration tests for facade interactions
  - [ ] Verify all existing tests still pass
- [ ] **Documentation**
  - [ ] Update inline documentation
  - [ ] Update API documentation
  - [ ] Create facade interaction diagrams
- [ ] **Performance validation**
  - [ ] Run performance benchmarks
  - [ ] Profile memory usage
  - [ ] Compare with baseline metrics

## Benefits and Outcomes

### Immediate Benefits
1. **Improved Maintainability**: 200-400 line modules vs 2000+ line monolith
2. **Better Testing**: Each facade can be unit tested independently
3. **Parallel Development**: Multiple developers can work on different features
4. **Code Reuse**: Common patterns between client and server can be shared

### Long-term Benefits
1. **Feature Velocity**: New features are easier to add to focused modules
2. **Bug Isolation**: Issues are contained to specific facades
3. **Learning Curve**: New developers can understand individual modules
4. **Performance**: Potential for facade-specific optimizations

### Success Metrics
- Main client file reduced from 2000+ to 500-600 lines
- Each facade module under 400 lines
- All existing tests pass without modification
- No performance regression in benchmarks
- Improved code coverage from module-specific tests

## Risk Mitigation

### Potential Risks
1. **Regression bugs** during refactoring
   - Mitigation: Comprehensive test coverage before starting
   - Incremental migration with tests at each step

2. **Performance impact** from indirection
   - Mitigation: Facade pattern uses compile-time generics (zero cost)
   - Profile before and after each phase

3. **API compatibility** for existing users
   - Mitigation: Public API remains unchanged
   - Internal refactoring only

## Timeline Estimate

- **Phase 1**: 1-2 days (preparation and testing)
- **Phase 2**: 3-5 days (incremental migration)
- **Phase 3**: 1-2 days (cleanup and optimization)
- **Total**: 5-9 days of focused effort

## Conclusion

The proposed refactoring will transform the QuicClient from a difficult-to-maintain monolith into a clean, modular architecture that matches the successful pattern used in the server. This will significantly improve code maintainability, testability, and developer experience while maintaining full backward compatibility and performance.

The incremental approach ensures that the refactoring can be done safely with minimal risk, and the facade pattern provides a proven architecture that has already demonstrated its value in the server implementation.