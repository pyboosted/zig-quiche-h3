# zig-quiche-h3 E2E Tests

This directory contains comprehensive end-to-end tests for the zig-quiche-h3 HTTP/3 server implementation.

## Prerequisites

- **Bun** >= 1.0.0
- **zig-quiche-h3 server and client** built with libev support
- Native h3-client binary (built automatically with the server)

## Setup

```bash
# Install test dependencies
bun install

# Build the server (if not already built)
bun run build

# Run type checking
bun run typecheck

# Format and lint code
bun run check
```

## Running Tests

### Basic Tests
```bash
# All tests with 60s timeout
bun test

# Only basic HTTP/3 and streaming tests (CI mode)
bun run test:ci

# Type check + lint + test
bun run check && bun test
```

### Stress Tests
```bash
# Enable stress tests (includes 1GB transfers, 100MB uploads)
bun run test:stress
```

### QLOG Tests
```bash
# Enable QLOG generation for debugging
bun run test:qlog
```

### Individual Test Suites
```bash
# Basic HTTP/3 functionality
bun test e2e/basic/

# Streaming downloads and uploads
bun test e2e/streaming/

# Specific test file
bun test e2e/basic/http3_basic.test.ts
```

## Environment Variables

- `H3_TEST_PORT`: Override random port selection (e.g., `H3_TEST_PORT=4433`)
- `H3_STRESS`: Enable stress tests (`H3_STRESS=1`)
- `H3_QLOG`: Enable QLOG generation (`H3_QLOG=1`) 
- `H3_DEBUG`: Enable debug logging and SSL key logging (`H3_DEBUG=1`)

## Test Structure

```
e2e/
├── helpers/           # Test utilities and server management
│   ├── spawnServer.ts # Server lifecycle management
│   ├── zigClient.ts   # Native h3-client wrapper (curl-compatible)
│   ├── curlClient.ts  # Legacy curl wrapper (not actively used)
│   ├── quicheClient.ts # Legacy quiche-client wrapper (not actively used)
│   └── testUtils.ts   # File generation, validation utilities
├── basic/             # Basic HTTP/3 functionality
│   ├── http3_basic.test.ts  # Connection, headers, methods
│   └── routing.test.ts      # Route matching and parameters
├── streaming/         # Streaming tests
│   ├── download.test.ts     # File downloads and generators
│   └── upload_stream.test.ts # Upload streaming with SHA-256
├── backpressure/      # Concurrency and flow control (planned)
└── qlog/              # QLOG validation (planned)
```

## Test Features Covered

### Basic HTTP/3 (M1-M4)
- ✅ QUIC handshake and connection establishment
- ✅ TLS certificate handling (self-signed)
- ✅ ALPN negotiation (h3, hq-interop)
- ✅ HEAD request fallback to GET
- ✅ HTTP methods (GET, POST, HEAD, DELETE)
- ✅ Static routes (`/`, `/api/users`)
- ✅ Parameterized routes (`/api/users/:id`)
- ✅ Wildcard routes (`/files/*`)
- ✅ JSON request/response handling
- ✅ Error responses (404, 405, 403)

### Streaming (M5)
- ✅ Download streaming (`/stream/test`, `/stream/1gb`)
- ✅ File serving with path safety (`/download/*`)
- ✅ Upload streaming with SHA-256 (`/upload/stream`)
- ✅ Push-mode streaming callbacks
- ✅ Backpressure handling
- ✅ Concurrent connections
- ✅ Large file transfers (1GB downloads, 100MB uploads)

### Security & Safety
- ✅ Path traversal protection
- ✅ Absolute path rejection
- ✅ TLS certificate validation
- ✅ Large header handling
- ✅ Content-length validation

## Performance Targets

- **Basic tests**: < 10s each
- **Streaming tests**: < 60s each
- **Stress tests**: < 10 minutes (gated by `H3_STRESS=1`)
- **Full CI suite**: < 2 minutes

## Debugging

### Enable Debug Logging
```bash
H3_DEBUG=1 bun test e2e/basic/http3_basic.test.ts
```

### Enable QLOG
```bash
H3_QLOG=1 bun test e2e/basic/http3_basic.test.ts
# Check qlogs/*.qlog files
```

### SSL Key Logging (Wireshark)
```bash
H3_DEBUG=1 bun test e2e/basic/http3_basic.test.ts
# Check tmp/sslkeylog-*.txt files
```

### Manual Server Testing
```bash
# Start server manually
../zig-out/bin/quic-server --port 4433 --cert ../third_party/quiche/quiche/examples/cert.crt --key ../third_party/quiche/quiche/examples/cert.key

# Test with native h3-client
../zig-out/bin/h3-client --url https://127.0.0.1:4433/ --insecure

# Test JSON routes
../zig-out/bin/h3-client --url https://127.0.0.1:4433/api/users --insecure

# Test H3 DATAGRAMs
../zig-out/bin/h3-client --url https://127.0.0.1:4433/h3dgram/echo --h3-dgram --dgram-payload "test" --insecure
```

## CI Integration

The tests are designed for CI environments:

- Hermetic: Each test spawns its own server
- Parallel: Tests run concurrently when safe
- Fast: Basic suite completes in < 2 minutes
- Reliable: No flaky tests or race conditions
- Clean: Automatic resource cleanup

## Troubleshooting

### Server Build Failures
```bash
# Clean and rebuild
rm -rf ../zig-out ../zig-cache
zig build -Dwith-libev=true -Dlibev-include=$(brew --prefix libev)/include -Dlibev-lib=$(brew --prefix libev)/lib
```

### Native Client Not Built
```bash
# Build h3-client
zig build h3-client -Dwith-libev=true -Dlibev-include=$(brew --prefix libev)/include -Dlibev-lib=$(brew --prefix libev)/lib

# Verify client is available
../zig-out/bin/h3-client --help
```

### Port Conflicts
```bash
# Use specific port
H3_TEST_PORT=14433 bun test

# Check port usage
lsof -i :4433
```

### Type Errors
```bash
# Run type checker
bun run typecheck

# Auto-fix linting issues
bun run lint
```

## Future Enhancements

- QUIC DATAGRAM tests (M6)
- HTTP/3 DATAGRAM tests (M7) 
- WebTransport tests (M8)
- Interop tests with other QUIC stacks
- Performance benchmarking
- Load testing scenarios