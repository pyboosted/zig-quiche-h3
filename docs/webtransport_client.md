# WebTransport Client Quickstart

This guide demonstrates how to exercise the WebTransport client helpers that were introduced in Milestone 4. The examples assume you are running from the repository root on macOS or Linux with Zig 0.15.1 installed. Because the QUIC runtime currently depends on `libev`, make sure the `ev.h` headers are available (for example via `brew install libev` on macOS or your distribution package on Linux) or provide the appropriate `-Dwith-libev=true`, `-Dlibev-include=…`, and `-Dlibev-lib=…` build options.

## 1. Build and Run the Example Server

The bundled QUIC server exposes a `/wt/echo` route that accepts WebTransport sessions, echoes DATAGRAM payloads, and mirrors stream data. Enable the feature gate before launching:

```bash
export H3_WEBTRANSPORT=1
zig build quic-server -- \
  --port 4433 \
  --cert third_party/quiche/quiche/examples/cert.crt \
  --key third_party/quiche/quiche/examples/cert.key
```

The server listens on `127.0.0.1:4433`, auto-accepts WebTransport sessions, and will log stream closures and DATAGRAM activity when debug logging is enabled.

## 2. Run the WebTransport Client

The `wt_client` example negotiates a session, sends one or more DATAGRAM payloads, and waits for their echoes before exiting. Run it alongside the example server:

```bash
zig build wt-client -- https://127.0.0.1:4433/wt/echo
```

Useful switches:

- `--quiet` suppresses the progress logs when scripting.
- `--count <n>` sends `n` datagrams (default: 1).
- `--payload-size <bytes>` overrides the payload length; the client fills the buffer with a repeating alphabet pattern so echoes are easy to recognise.

The process exits with code `0` once the configured datagrams are echoed back; failures (handshake, timeout, send errors) return a non-zero status and print the reason to stderr.

## 3. Client Configuration Knobs

Milestone 4 added WebTransport-centric knobs to `QuicClient` configuration:

- `wt_max_outgoing_uni` / `wt_max_outgoing_bidi` – soft caps for locally initiated streams.
- `wt_stream_recv_queue_len` / `wt_stream_recv_buffer_bytes` – backpressure limits for buffered inbound stream data.

The example client uses conservative defaults. To try different limits, clone the repo and edit the `ClientConfig` literal in `src/examples/wt_client.zig`.

## 4. Expected Output

With the server echo route running, the client prints lines similar to:

```
WebTransport session established!
Session ID: 4
Sent: WebTransport datagram #0 (len=1200)
Received echo: WebTransport datagram #0 (len=1200)
WebTransport test complete!
```

Use `--quiet` when scripting to suppress these logs.

## 5. Cleanup

The example exits automatically after the first successful echo (or when the timeout expires). Restart it to send another datagram. To customise payloads or stream behaviour, adjust `src/examples/wt_client.zig` and rebuild.

## 6. Collecting QLOG Traces

- The example server writes one qlog per connection to the `qlogs/` directory (the filename is derived from the connection ID). Pass `--no_qlog` to the server binary if you want to disable capture.
- The client stores its trace in `qlogs/client/` so you can inspect both perspectives of the same run. Remove the directory between experiments to keep captures organised.
- Visualise the traces with [qvis](https://qvis.edm.uhasselt.be/) or another qlog viewer to inspect handshake progress, datagram exchanges, and shutdown semantics.
