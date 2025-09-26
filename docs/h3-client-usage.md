# h3-client Usage Guide

## Overview

The `h3-client` is a native HTTP/3 client built with Zig and quiche, providing a curl-compatible interface with extended features for advanced HTTP/3 testing including H3 DATAGRAMs, WebTransport, and connection pooling.

## Building

```bash
# Initialize submodules if not done
git submodule update --init --recursive

# Build with libev support (required)
zig build h3-client -Dwith-libev=true \
  -Dlibev-include=$(brew --prefix libev)/include \
  -Dlibev-lib=$(brew --prefix libev)/lib

# The binary will be at: ./zig-out/bin/h3-client
```

## Basic Usage

### Simple GET Request
```bash
# Basic GET request
./zig-out/bin/h3-client --url https://example.com/

# With insecure mode for self-signed certificates
./zig-out/bin/h3-client --url https://127.0.0.1:4433/ --insecure

# Silent mode (no debug output)
./zig-out/bin/h3-client --url https://example.com/ --silent
```

### HTTP Methods
```bash
# POST request with data
./zig-out/bin/h3-client --url https://example.com/api \
  --method POST \
  --body '{"name":"test"}'

# POST from file
./zig-out/bin/h3-client --url https://example.com/upload \
  --method POST \
  --body-file data.json

# HEAD request
./zig-out/bin/h3-client --url https://example.com/ --method HEAD

# DELETE request
./zig-out/bin/h3-client --url https://example.com/item/123 --method DELETE
```

### Custom Headers
```bash
# Single header
./zig-out/bin/h3-client --url https://example.com/ \
  --header "Authorization: Bearer token"

# Multiple headers
./zig-out/bin/h3-client --url https://example.com/ \
  --header "Authorization: Bearer token" \
  --header "Content-Type: application/json" \
  --header "X-Custom: value"
```

## Advanced Features

### H3 DATAGRAMs
```bash
# Send H3 DATAGRAM with request
./zig-out/bin/h3-client --url https://127.0.0.1:4433/h3dgram/echo \
  --h3-dgram \
  --dgram-payload "Hello DATAGRAM" \
  --insecure

# Send DATAGRAM from file
./zig-out/bin/h3-client --url https://127.0.0.1:4433/h3dgram/echo \
  --h3-dgram \
  --dgram-payload-file datagram.bin \
  --insecure

# Multiple DATAGRAMs with interval
./zig-out/bin/h3-client --url https://127.0.0.1:4433/h3dgram/echo \
  --h3-dgram \
  --dgram-payload "test" \
  --dgram-count 5 \
  --dgram-interval-ms 100 \
  --insecure

# Wait for DATAGRAM responses
./zig-out/bin/h3-client --url https://127.0.0.1:4433/h3dgram/echo \
  --h3-dgram \
  --dgram-payload "test" \
  --dgram-wait-ms 2000 \
  --insecure
```

### WebTransport
```bash
# Enable WebTransport support
./zig-out/bin/h3-client --url https://127.0.0.1:4433/wt/echo \
  --enable-webtransport \
  --insecure
```

### Concurrent Requests
```bash
# Make 10 requests sequentially
./zig-out/bin/h3-client --url https://example.com/ \
  --repeat 10 \
  --insecure

# Future: Connection pooling (in development)
# --pool flag will enable connection reuse across requests
```

### Streaming and Rate Limiting
```bash
# Stream response body
./zig-out/bin/h3-client --url https://example.com/large-file \
  --stream \
  --insecure

# Rate limit download (e.g., 100KB/s)
./zig-out/bin/h3-client --url https://example.com/large-file \
  --stream \
  --limit-rate 100K \
  --insecure

# Stream request body from file
./zig-out/bin/h3-client --url https://example.com/upload \
  --method POST \
  --body-file large.bin \
  --body-file-stream \
  --insecure
```

## Output Formats

### Curl Compatibility Mode (Default)
```bash
# Include headers in output (like curl -i)
./zig-out/bin/h3-client --url https://example.com/ \
  --curl-compat \
  --include-headers \
  --insecure

# Output format matches curl for easy migration
```

### JSON Output
```bash
# Get response as JSON (for scripting)
./zig-out/bin/h3-client --url https://example.com/ \
  --json \
  --insecure
```

### Body Only
```bash
# Suppress headers, output body only
./zig-out/bin/h3-client --url https://example.com/ \
  --output-body \
  --insecure
```

## Timeout and Connection Options

```bash
# Set timeout (milliseconds)
./zig-out/bin/h3-client --url https://example.com/ \
  --timeout-ms 5000 \
  --insecure

# Enable qlog output for debugging
./zig-out/bin/h3-client --url https://example.com/ \
  --qlog-dir ./qlogs \
  --insecure
```

## Testing Against Local Server

```bash
# Start the local server
./zig-out/bin/quic-server \
  --port 4433 \
  --cert third_party/quiche/quiche/examples/cert.crt \
  --key third_party/quiche/quiche/examples/cert.key

# Test basic connectivity
./zig-out/bin/h3-client --url https://127.0.0.1:4433/ --insecure

# Test JSON API routes
./zig-out/bin/h3-client --url https://127.0.0.1:4433/api/users --insecure

# Test H3 DATAGRAM echo
./zig-out/bin/h3-client --url https://127.0.0.1:4433/h3dgram/echo \
  --h3-dgram \
  --dgram-payload "echo test" \
  --dgram-wait-ms 1000 \
  --insecure

# Test file download
./zig-out/bin/h3-client --url https://127.0.0.1:4433/download/test.txt \
  --insecure

# Test streaming
./zig-out/bin/h3-client --url https://127.0.0.1:4433/stream/test \
  --stream \
  --insecure
```

## E2E Test Integration

The h3-client is used by the E2E test suite through the `zigClient` TypeScript wrapper:

```typescript
// tests/e2e/helpers/zigClient.ts
import { zigClient } from "@helpers/zigClient";

// Simple GET request
const response = await zigClient("https://127.0.0.1:4433/");

// With H3 DATAGRAMs
const response = await zigClient("https://127.0.0.1:4433/h3dgram/echo", {
    h3Dgram: true,
    dgramPayload: "test",
    dgramWaitMs: 1000
});

// Concurrent requests
const response = await zigClient("https://127.0.0.1:4433/", {
    concurrent: 5
});
```

## Command Line Reference

```
h3-client - Native HTTP/3 client with curl compatibility

USAGE:
    h3-client --url <URL> [OPTIONS]

REQUIRED:
    --url <URL>                 HTTPS URL to request

CONNECTION OPTIONS:
    --insecure                  Skip certificate verification (default)
    --verify-peer               Verify server certificate
    --timeout-ms <ms>           Request timeout in milliseconds (default: 30000)
    --qlog-dir <dir>            Directory for qlog output

REQUEST OPTIONS:
    --method <METHOD>           HTTP method (GET, POST, HEAD, etc.)
    --header <HEADER>           Add custom header (can be repeated)
    --body <DATA>               Request body data
    --body-file <FILE>          Read request body from file
    --body-file-stream          Stream request body from file

H3 DATAGRAM OPTIONS:
    --h3-dgram                  Enable H3 DATAGRAM support
    --dgram-payload <DATA>      DATAGRAM payload to send
    --dgram-payload-file <FILE> Read DATAGRAM payload from file
    --dgram-count <N>           Number of DATAGRAMs to send
    --dgram-interval-ms <ms>    Interval between DATAGRAMs
    --dgram-wait-ms <ms>        Wait for DATAGRAM responses

WEBTRANSPORT OPTIONS:
    --enable-webtransport       Enable WebTransport support

OUTPUT OPTIONS:
    --silent, -s                Suppress debug output
    --include-headers           Include response headers in output
    --curl-compat               Curl-compatible output format (default)
    --json                      Output as JSON
    --output-body               Output response body only

STREAMING OPTIONS:
    --stream                    Enable streaming mode
    --limit-rate <RATE>         Limit transfer rate (e.g., 100K, 1M)

CONCURRENT OPTIONS:
    --repeat <N>                Repeat request N times

EXAMPLES:
    # Basic GET request
    h3-client --url https://example.com/

    # POST with JSON
    h3-client --url https://example.com/api \
      --method POST \
      --header "Content-Type: application/json" \
      --body '{"key":"value"}'

    # H3 DATAGRAM test
    h3-client --url https://127.0.0.1:4433/h3dgram/echo \
      --h3-dgram \
      --dgram-payload "test" \
      --insecure

    # Stream large file with rate limit
    h3-client --url https://example.com/large.bin \
      --stream \
      --limit-rate 1M \
      --insecure
```

## Migration from curl

The h3-client provides a mostly curl-compatible interface for easy migration:

| curl option | h3-client equivalent |
|------------|---------------------|
| `curl URL` | `h3-client --url URL` |
| `curl -X POST` | `h3-client --method POST` |
| `curl -H "Header: Value"` | `h3-client --header "Header: Value"` |
| `curl -d "data"` | `h3-client --body "data"` |
| `curl -d @file` | `h3-client --body-file file` |
| `curl -i` | `h3-client --include-headers` |
| `curl -s` | `h3-client --silent` |
| `curl -k` | `h3-client --insecure` |
| `curl --http3-only` | (HTTP/3 by default) |

## Troubleshooting

### Certificate Verification Errors
```bash
# Use --insecure for self-signed certificates
./zig-out/bin/h3-client --url https://127.0.0.1:4433/ --insecure
```

### Connection Timeouts
```bash
# Increase timeout
./zig-out/bin/h3-client --url https://slow-server.com/ \
  --timeout-ms 60000 \
  --insecure
```

### Debug Connection Issues
```bash
# Enable qlog for detailed debugging
./zig-out/bin/h3-client --url https://example.com/ \
  --qlog-dir ./qlogs \
  --insecure

# View qlogs with qvis: https://qvis.edm.uhasselt.be/
```

### Build Issues
```bash
# Ensure libev is installed
brew install libev  # macOS
apt-get install libev-dev  # Linux

# Rebuild with correct paths
zig build h3-client -Dwith-libev=true \
  -Dlibev-include=/usr/local/include \
  -Dlibev-lib=/usr/local/lib
```

## Future Enhancements

- Connection pooling for improved performance
- Full WebTransport stream support
- HTTP/3 priority support
- 0-RTT support
- Multiplexed concurrent requests over single connection
- Response caching
- Cookie jar support
- Proxy support