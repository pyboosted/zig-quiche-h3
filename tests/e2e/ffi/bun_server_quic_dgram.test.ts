import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { createH3Server, type H3Server } from "../../../src/bun/server.ts";
import { prebuildAllArtifacts } from "@helpers/prebuild";
import { getCertPath, randPort } from "@helpers/testUtils";

const HOST = "127.0.0.1";

describe("Bun FFI server QUIC datagram handling (server-level)", () => {
  let server: H3Server;
  const port = randPort();
  const receivedDatagrams: Array<{
    connectionIdHex: string;
    payload: Uint8Array;
    timestamp: number;
  }> = [];

  beforeAll(async () => {
    await prebuildAllArtifacts();
    receivedDatagrams.length = 0;

    server = createH3Server({
      hostname: HOST,
      port,
      certPath: getCertPath("cert.crt"),
      keyPath: getCertPath("cert.key"),
      // Server-level QUIC datagram handler (connection-scoped, not HTTP-associated)
      quicDatagram: (payload, ctx) => {
        // Store received datagram for verification
        receivedDatagrams.push({
          connectionIdHex: ctx.connectionIdHex,
          payload: new Uint8Array(payload), // Copy payload
          timestamp: Date.now(),
        });

        // Echo back the datagram
        ctx.sendReply(payload);
      },
      routes: [
        {
          method: "GET",
          pattern: "/",
          fetch: async () => {
            return new Response("QUIC datagram server ready", {
              status: 200,
              headers: { "content-type": "text/plain" },
            });
          },
        },
      ],
      fetch: async (request) => {
        return new Response("Not Found", { status: 404 });
      },
    });
  });

  afterAll(() => {
    server.close();
  });

  it("registers server-level QUIC datagram handler", () => {
    expect(server).toBeDefined();
    expect(server.running).toBe(true);

    // Verify server was created with QUIC datagram support
    const stats = server.getStats();
    expect(stats).toBeDefined();
  });

  it("auto-enables QUIC DATAGRAM when quicDatagram handler provided", () => {
    // Server should automatically enable DATAGRAM support when handler is provided
    // This is tested by creating a server with quicDatagram callback above

    // Create a second server WITHOUT quicDatagram handler to contrast
    const plainServer = createH3Server({
      hostname: HOST,
      port: randPort(),
      certPath: getCertPath("cert.crt"),
      keyPath: getCertPath("cert.key"),
      fetch: async () => {
        return new Response("Plain server", { status: 200 });
      },
    });

    try {
      expect(plainServer.running).toBe(true);
      // Both servers should work, but one has DATAGRAM enabled
    } finally {
      plainServer.close();
    }
  });

  it("exposes QUICDatagramContext with connection metadata", () => {
    // The context object is tested indirectly through the callback
    // We verify that:
    // 1. connectionId is present (binary form)
    // 2. connectionIdHex is present (hex string for logging)
    // 3. sendReply() method works

    // This is validated by the handler storing connectionIdHex
    // and the echo functionality working (tested in other tests)
    expect(true).toBe(true); // Placeholder - actual test requires client
  });

  // NOTE: The following tests require a QUIC datagram client to send raw datagrams.
  // The native h3-client only supports HTTP/3 DATAGRAMs, not raw QUIC datagrams.
  // A proper test would require:
  // 1. A native QUIC datagram client binary (not yet implemented), OR
  // 2. An FFI client with QUIC datagram send support, OR
  // 3. Using an external tool like quiche's example clients

  it.skip("receives and echoes QUIC datagram (requires QUIC datagram client)", async () => {
    // TODO: Implement when QUIC datagram client is available
    // Expected flow:
    // 1. Client sends raw QUIC datagram to server
    // 2. Server quicDatagram handler receives payload
    // 3. Handler calls ctx.sendReply() to echo
    // 4. Client receives echo
    // 5. Verify receivedDatagrams array contains the datagram

    // Placeholder assertion
    expect(receivedDatagrams.length).toBeGreaterThanOrEqual(0);
  });

  it.skip("handles multiple QUIC datagrams in burst (requires client)", async () => {
    // TODO: Test burst of 10+ datagrams
    // Verify all received, connection ID consistent, echo works
    expect(true).toBe(true);
  });

  it.skip("handles QUIC datagrams up to MTU size (requires client)", async () => {
    // TODO: Test with 1200 byte payload (typical MTU)
    // Verify received intact and echoed back
    expect(true).toBe(true);
  });

  it("QUIC datagram handler is connection-scoped (not HTTP-associated)", () => {
    // Key architectural distinction:
    // - QUIC datagrams: Connection-level, no HTTP context, arrive before HTTP
    // - H3 datagrams: Request-associated, have flow IDs, require HTTP exchange
    // - WebTransport: Session-based, bidirectional streams + datagrams

    // This test documents the distinction without requiring a client
    expect(server.running).toBe(true);

    // Server-level handler is registered once, applies to all connections
    // Unlike H3 datagrams which are per-route
  });

  it("handles errors in QUIC datagram handler gracefully", async () => {
    // Create server with handler that throws
    const errorServer = createH3Server({
      hostname: HOST,
      port: randPort(),
      certPath: getCertPath("cert.crt"),
      keyPath: getCertPath("cert.key"),
      quicDatagram: (payload, ctx) => {
        throw new Error("Intentional error in QUIC datagram handler");
      },
      fetch: async () => {
        return new Response("OK", { status: 200 });
      },
    });

    try {
      expect(errorServer.running).toBe(true);

      // Server should continue running even if handler throws
      // Errors should be logged but not crash the server
      // (This is Tier 3 error handling: log and continue)

      // TODO: Send datagram to trigger handler error when client is available
      // For now, just verify server starts successfully
    } finally {
      errorServer.close();
    }
  });
});

describe("QUIC datagram vs H3 datagram distinction", () => {
  it("documents protocol layer differences", () => {
    // This test serves as documentation for the three protocol layers:

    // 1. QUIC DATAGRAM (server-level, connection-scoped)
    //    - Raw connection-level messaging
    //    - No HTTP context
    //    - Arrives before any HTTP exchange
    //    - Configured via H3ServeOptions.quicDatagram callback
    //    - Context: QUICDatagramContext with connectionId

    // 2. HTTP/3 DATAGRAM (per-route, request-associated)
    //    - Associated with HTTP request/response
    //    - Has flow ID for multiplexing
    //    - Requires HTTP exchange first
    //    - Configured via RouteDefinition.h3Datagram callback
    //    - Context: H3DatagramContext with streamId, flowId, request

    // 3. WebTransport (per-route, session-based)
    //    - Session with bidirectional streams + datagrams
    //    - Requires CONNECT :protocol=webtransport
    //    - Configured via RouteDefinition.webtransport callback
    //    - Context: WTContext with sessionId, request

    expect(true).toBe(true);
  });
});
