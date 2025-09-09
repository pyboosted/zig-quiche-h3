# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview
This is a Zig implementation of QUIC/HTTP-3 built on Cloudflare's quiche library (v0.24.6) via C FFI. The project uses libev for event-driven I/O and demonstrates incremental development through milestones from UDP echo to full HTTP/3 support.

## Critical Build Commands

### Prerequisites
```bash
# Initialize quiche submodule (required once)
git submodule update --init --recursive

# Build quiche library (required before first Zig build)
cd third_party/quiche && cargo build --release --features ffi,qlog
```

### Build & Run
```bash
# Build everything with libev support (required for servers)
zig build -Dwith-libev=true

# Build with specific libev paths (macOS example)
zig build -Dwith-libev=true -Dlibev-include=$(brew --prefix libev)/include -Dlibev-lib=$(brew --prefix libev)/lib

# Run QUIC/HTTP-3 server
./zig-out/bin/quic-server 127.0.0.1:4433

# Test HTTP/3 with quiche-client
cargo run -p quiche_apps --bin quiche-client -- https://127.0.0.1:4433/ --no-verify

# Run UDP echo server (simpler test)
zig build echo -Dwith-libev=true
```

### Testing & Development
```bash
# Run unit tests
zig build test

# Format code before commits
zig fmt .

# Clean build artifacts
rm -rf zig-cache/ zig-out/ .zig-cache/
```

## Architecture & Key Design Decisions

### Module Organization
The codebase follows a layered architecture with clear separation of concerns:

1. **FFI Layer** (`src/ffi/quiche.zig`): Direct C bindings to quiche with Zig-idiomatic wrappers
   - Handles all C interop including pointer conversions and error mapping
   - Provides both QUIC and H3 namespaces with proper type safety
   - Critical: Uses `[*c]u8` for C pointers, not `[*]const u8`

2. **Network Layer** (`src/net/`): Event loop abstraction and UDP handling
   - `event_loop.zig`: libev integration with IO/timer/signal watchers
   - `udp.zig`: Dual-stack IPv6/IPv4 support with atomic socket flags
   - Uses non-blocking I/O throughout

3. **QUIC Layer** (`src/quic/`): Connection management and protocol handling
   - `server.zig`: Main server with connection table (HashMap by DCID)
   - `connection.zig`: Per-connection state and lifecycle
   - `config.zig`: TLS, ALPN, transport parameters
   - Implements timer-based timeout processing

4. **HTTP/3 Layer** (`src/h3/`): HTTP/3 protocol implementation
   - `connection.zig`: H3 connection lifecycle, lazy creation after handshake
   - `event.zig`: Header iteration with careful memory management
   - `config.zig`: Safe defaults (16KB headers, disabled QPACK)
   - Only created when ALPN negotiates "h3"

### Critical Implementation Details

**Memory Management:**
- H3 connections stored as opaque pointers in QUIC connections
- Headers duplicated during collection for safe lifetime management
- Proper cleanup in all deinit() methods
- ArrayList is unmanaged in Zig 0.15 - pass allocator to methods

**Event Processing Flow:**
1. UDP packet arrives → libev IO watcher triggers
2. Server processes packets, updates connection state
3. For H3 connections: poll events, handle Headers/Data/Finished
4. Send responses via quiche's egress mechanism
5. Timer processes timeouts and cleanup

**ALPN & Protocol Selection:**
- Server advertises: `["h3", "hq-interop"]`
- H3 connection created only when client selects "h3"
- Falls back to raw QUIC streams for "hq-interop"

**Error Handling:**
- Non-fatal errors (Done, StreamBlocked) handled gracefully
- C API errors mapped to Zig error enums
- QLOG enabled by default for debugging

## Common Development Patterns

### Adding New H3 Features
1. Extend FFI bindings in `src/ffi/quiche.zig` h3 namespace
2. Add high-level wrapper in `src/h3/` modules
3. Integrate in `processH3()` method in server.zig
4. Test with quiche-client

### Debugging Connection Issues
1. Check qlogs in project root (not third_party)
2. Enable QUICHE_LOG via environment variable
3. Look for handshake completion messages
4. Verify ALPN negotiation in logs

### FFI Pattern for New Bindings
```zig
// In src/ffi/quiche.zig
pub fn newFunction(param: *Connection) !ReturnType {
    const result = c.quiche_function(param.ptr);
    if (result < 0) return errorFromSsize(result);
    return @intCast(result);
}
```

## Platform-Specific Notes

### macOS
- libev from Homebrew: paths must be specified explicitly
- Dual-stack sockets work with V6ONLY=0
- Use `lsof -i :4433` to check port binding

### Linux
- libev usually in system paths
- May need `libssl-dev` for SSL features
- Use `ss -ulpn | grep 4433` for port check

## Zig 0.15 Compatibility
- Zig version: use Zig 0.15.1 or later.
- Call conventions: use `.c` (lowercase), not `.C`
- ArrayList: unmanaged, requires `std.ArrayList(T){}` init
- Pass allocator to ArrayList methods: `list.append(allocator, item)`
- Use `@bitOffsetOf` for portable flag detection
- Do not skip tests ever, until i ask directly