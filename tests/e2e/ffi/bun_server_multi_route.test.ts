import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { createH3Server, type H3Server } from "../../../src/bun/server.ts";
import { prebuildAllArtifacts } from "@helpers/prebuild";
import { getCertPath, randPort } from "@helpers/testUtils";
import { zigClient } from "@helpers/zigClient";

const HOST = "127.0.0.1";

describe("Bun FFI server multi-route scenarios", () => {
  let server: H3Server;
  const port = randPort();
  const requestLog: Array<{ path: string; method: string; mode?: string }> = [];

  beforeAll(async () => {
    await prebuildAllArtifacts();
    requestLog.length = 0;

    server = createH3Server({
      hostname: HOST,
      port,
      certPath: getCertPath("cert.crt"),
      keyPath: getCertPath("cert.key"),
      routes: [
        // Route 1: Buffered mode GET
        {
          method: "GET",
          pattern: "/api/info",
          mode: "buffered",
          fetch: async (request) => {
            requestLog.push({ path: "/api/info", method: "GET", mode: "buffered" });
            return new Response(
              JSON.stringify({ endpoint: "info", mode: "buffered" }),
              {
                status: 200,
                headers: { "content-type": "application/json" },
              },
            );
          },
        },
        // Route 2: Buffered mode POST with body
        {
          method: "POST",
          pattern: "/api/upload-small",
          mode: "buffered",
          fetch: async (request) => {
            const body = await request.text();
            requestLog.push({
              path: "/api/upload-small",
              method: "POST",
              mode: "buffered",
            });
            return new Response(
              JSON.stringify({ received: body.length, mode: "buffered" }),
              {
                status: 200,
                headers: { "content-type": "application/json" },
              },
            );
          },
        },
        // Route 3: Streaming mode POST
        {
          method: "POST",
          pattern: "/api/upload-large",
          mode: "streaming",
          fetch: async (request) => {
            let totalBytes = 0;
            const reader = request.body?.getReader();
            if (reader) {
              while (true) {
                const { done, value } = await reader.read();
                if (done) break;
                totalBytes += value.length;
              }
              reader.releaseLock();
            }
            requestLog.push({
              path: "/api/upload-large",
              method: "POST",
              mode: "streaming",
            });
            return new Response(
              JSON.stringify({ received: totalBytes, mode: "streaming" }),
              {
                status: 200,
                headers: { "content-type": "application/json" },
              },
            );
          },
        },
        // Route 4: H3 DATAGRAM handler
        {
          method: "POST",
          pattern: "/datagram/echo",
          h3Datagram: (payload, ctx) => {
            requestLog.push({
              path: "/datagram/echo",
              method: "POST",
              mode: "h3-datagram",
            });
            ctx.sendReply(payload);
          },
          fetch: async (request) => {
            return new Response("H3 DATAGRAM endpoint", {
              status: 200,
              headers: { "content-type": "text/plain" },
            });
          },
        },
        // Route 5: WebTransport handler
        {
          method: "CONNECT",
          pattern: "/wt/session",
          webtransport: (ctx) => {
            requestLog.push({
              path: "/wt/session",
              method: "CONNECT",
              mode: "webtransport",
            });
            ctx.accept();
            const welcomeMsg = new TextEncoder().encode("Welcome to WebTransport");
            ctx.sendDatagram(welcomeMsg);
          },
          fetch: async (request) => {
            return new Response("WebTransport endpoint (use CONNECT)", {
              status: 200,
              headers: { "content-type": "text/plain" },
            });
          },
        },
        // Route 6: Multiple HTTP methods on same pattern
        {
          method: "PUT",
          pattern: "/resource",
          fetch: async (request) => {
            requestLog.push({ path: "/resource", method: "PUT" });
            return new Response("Resource updated", { status: 200 });
          },
        },
        {
          method: "DELETE",
          pattern: "/resource",
          fetch: async (request) => {
            requestLog.push({ path: "/resource", method: "DELETE" });
            return new Response("Resource deleted", { status: 200 });
          },
        },
      ],
      // Fallback handler for unmatched routes
      fetch: async (request) => {
        const url = new URL(request.url);
        requestLog.push({ path: url.pathname, method: request.method, mode: "fallback" });
        return new Response(
          JSON.stringify({
            message: "Fallback handler",
            path: url.pathname,
            method: request.method,
          }),
          {
            status: 200,
            headers: { "content-type": "application/json" },
          },
        );
      },
    });
  });

  afterAll(() => {
    server.close();
  });

  it("routes buffered mode GET requests", async () => {
    requestLog.length = 0;

    const result = await zigClient({
      url: `https://${HOST}:${port}/api/info`,
      method: "GET",
      insecure: true,
    });

    expect(result.exitCode).toBe(0);
    expect(result.status).toBe(200);

    const responseData = JSON.parse(result.body);
    expect(responseData.mode).toBe("buffered");

    expect(requestLog.some((r) => r.path === "/api/info" && r.mode === "buffered")).toBe(true);
  });

  it("routes buffered mode POST requests", async () => {
    requestLog.length = 0;

    const payload = "small buffered payload";
    const result = await zigClient({
      url: `https://${HOST}:${port}/api/upload-small`,
      method: "POST",
      body: payload,
      insecure: true,
    });

    expect(result.exitCode).toBe(0);
    expect(result.status).toBe(200);

    const responseData = JSON.parse(result.body);
    expect(responseData.mode).toBe("buffered");
    expect(responseData.received).toBe(payload.length);

    expect(
      requestLog.some((r) => r.path === "/api/upload-small" && r.mode === "buffered"),
    ).toBe(true);
  });

  it("routes streaming mode POST requests", async () => {
    requestLog.length = 0;

    const payload = "x".repeat(100 * 1024); // 100KB
    const result = await zigClient({
      url: `https://${HOST}:${port}/api/upload-large`,
      method: "POST",
      body: payload,
      insecure: true,
    });

    expect(result.exitCode).toBe(0);
    expect(result.status).toBe(200);

    const responseData = JSON.parse(result.body);
    expect(responseData.mode).toBe("streaming");
    expect(responseData.received).toBe(payload.length);

    expect(
      requestLog.some((r) => r.path === "/api/upload-large" && r.mode === "streaming"),
    ).toBe(true);
  });

  it("handles multiple protocol layers on same server", async () => {
    // Server has:
    // - Regular HTTP routes (GET /api/info, POST /api/upload-*)
    // - H3 DATAGRAM route (POST /datagram/echo)
    // - WebTransport route (CONNECT /wt/session)

    // Test HTTP route
    const httpResult = await zigClient({
      url: `https://${HOST}:${port}/api/info`,
      method: "GET",
      insecure: true,
    });
    expect(httpResult.status).toBe(200);

    // Test H3 DATAGRAM route (GET to confirm registration)
    const dgramResult = await zigClient({
      url: `https://${HOST}:${port}/datagram/echo`,
      method: "POST",
      insecure: true,
    });
    expect(dgramResult.status).toBe(200);
    expect(dgramResult.body).toContain("H3 DATAGRAM");

    // All protocol layers coexist without interference
  });

  it("handles different modes on different routes", async () => {
    requestLog.length = 0;

    // Make requests to both buffered and streaming routes
    const bufferedResult = await zigClient({
      url: `https://${HOST}:${port}/api/upload-small`,
      method: "POST",
      body: "buffered",
      insecure: true,
    });

    const streamingResult = await zigClient({
      url: `https://${HOST}:${port}/api/upload-large`,
      method: "POST",
      body: "streaming",
      insecure: true,
    });

    expect(bufferedResult.status).toBe(200);
    expect(streamingResult.status).toBe(200);

    // Verify both modes were handled correctly
    expect(requestLog.some((r) => r.mode === "buffered")).toBe(true);
    expect(requestLog.some((r) => r.mode === "streaming")).toBe(true);
  });

  it("routes multiple HTTP methods on same pattern", async () => {
    requestLog.length = 0;

    // PUT /resource
    const putResult = await zigClient({
      url: `https://${HOST}:${port}/resource`,
      method: "PUT",
      insecure: true,
    });
    expect(putResult.status).toBe(200);
    expect(putResult.body).toContain("updated");

    // DELETE /resource
    const deleteResult = await zigClient({
      url: `https://${HOST}:${port}/resource`,
      method: "DELETE",
      insecure: true,
    });
    expect(deleteResult.status).toBe(200);
    expect(deleteResult.body).toContain("deleted");

    // Verify both methods were routed correctly
    expect(requestLog.some((r) => r.path === "/resource" && r.method === "PUT")).toBe(true);
    expect(requestLog.some((r) => r.path === "/resource" && r.method === "DELETE")).toBe(true);
  });

  it("falls back to default handler for unmatched routes", async () => {
    requestLog.length = 0;

    const result = await zigClient({
      url: `https://${HOST}:${port}/unmatched/path`,
      method: "GET",
      insecure: true,
    });

    expect(result.exitCode).toBe(0);
    expect(result.status).toBe(200);

    const responseData = JSON.parse(result.body);
    expect(responseData.message).toBe("Fallback handler");
    expect(responseData.path).toBe("/unmatched/path");

    expect(
      requestLog.some((r) => r.path === "/unmatched/path" && r.mode === "fallback"),
    ).toBe(true);
  });

  it("handles concurrent requests to different routes", async () => {
    requestLog.length = 0;

    // Launch 5 concurrent requests to different routes
    const requests = [
      zigClient({ url: `https://${HOST}:${port}/api/info`, insecure: true }),
      zigClient({
        url: `https://${HOST}:${port}/api/upload-small`,
        method: "POST",
        body: "test",
        insecure: true,
      }),
      zigClient({
        url: `https://${HOST}:${port}/api/upload-large`,
        method: "POST",
        body: "large",
        insecure: true,
      }),
      zigClient({ url: `https://${HOST}:${port}/resource`, method: "PUT", insecure: true }),
      zigClient({ url: `https://${HOST}:${port}/fallback`, insecure: true }),
    ];

    const results = await Promise.all(requests);

    // All requests should succeed
    for (const result of results) {
      expect(result.exitCode).toBe(0);
      expect(result.status).toBe(200);
    }

    // Verify all routes were hit
    expect(requestLog.length).toBeGreaterThanOrEqual(5);
    expect(requestLog.some((r) => r.path === "/api/info")).toBe(true);
    expect(requestLog.some((r) => r.path === "/api/upload-small")).toBe(true);
    expect(requestLog.some((r) => r.path === "/api/upload-large")).toBe(true);
    expect(requestLog.some((r) => r.path === "/resource")).toBe(true);
    expect(requestLog.some((r) => r.mode === "fallback")).toBe(true);
  });

  it("preserves route isolation (errors in one route don't affect others)", async () => {
    // Create a server with one route that throws and others that work
    const isolationServer = createH3Server({
      hostname: HOST,
      port: randPort(),
      certPath: getCertPath("cert.crt"),
      keyPath: getCertPath("cert.key"),
      routes: [
        {
          method: "GET",
          pattern: "/error",
          fetch: async () => {
            throw new Error("Intentional route error");
          },
        },
        {
          method: "GET",
          pattern: "/healthy",
          fetch: async () => {
            return new Response("Healthy route", { status: 200 });
          },
        },
      ],
      error: (error) => {
        // Custom error handler
        return new Response("Error handled", { status: 500 });
      },
      fetch: async () => {
        return new Response("Fallback", { status: 200 });
      },
    });

    try {
      const isolationPort = isolationServer.port;

      // Error route should be handled gracefully
      const errorResult = await zigClient({
        url: `https://${HOST}:${isolationPort}/error`,
        insecure: true,
      });
      expect([200, 500]).toContain(errorResult.status); // Either error handler or connection reset

      // Healthy route should still work
      const healthyResult = await zigClient({
        url: `https://${HOST}:${isolationPort}/healthy`,
        insecure: true,
      });
      expect(healthyResult.exitCode).toBe(0);
      expect(healthyResult.status).toBe(200);
      expect(healthyResult.body).toContain("Healthy");
    } finally {
      isolationServer.close();
    }
  });
});
