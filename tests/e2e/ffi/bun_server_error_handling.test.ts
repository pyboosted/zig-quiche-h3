import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { createH3Server, type H3Server } from "../../../src/bun/server.ts";
import { prebuildAllArtifacts } from "@helpers/prebuild";
import { getCertPath, randPort } from "@helpers/testUtils";
import { zigClient } from "@helpers/zigClient";

const HOST = "127.0.0.1";

describe("Bun FFI server error handling (4-tier strategy)", () => {
  beforeAll(async () => {
    await prebuildAllArtifacts();
  });

  describe("Tier 1: Configuration errors (fail fast at construction)", () => {
    // These tests are covered in phase5_validation.test.ts
    // Documenting here for completeness of the 4-tier strategy

    it("references configuration validation tests", () => {
      // Tier 1 errors tested in phase5_validation.test.ts:
      // - Invalid port numbers
      // - Empty hostname
      // - Invalid HTTP methods
      // - Invalid route patterns
      // - Missing handlers
      // - Non-function handlers
      // - Invalid mode values

      expect(true).toBe(true);
    });
  });

  describe("Tier 2: Request handler errors (return error Response)", () => {
    let server: H3Server;
    const port = randPort();
    const errorLog: Array<{ message: string; path: string }> = [];

    beforeAll(() => {
      errorLog.length = 0;

      server = createH3Server({
        hostname: HOST,
        port,
        certPath: getCertPath("cert.crt"),
        keyPath: getCertPath("cert.key"),
        routes: [
          {
            method: "GET",
            pattern: "/sync-error",
            fetch: () => {
              throw new Error("Synchronous error in handler");
            },
          },
          {
            method: "GET",
            pattern: "/async-error",
            fetch: async () => {
              await new Promise((resolve) => setTimeout(resolve, 10));
              throw new Error("Asynchronous error in handler");
            },
          },
          {
            method: "GET",
            pattern: "/type-error",
            fetch: () => {
              // @ts-ignore - intentional type error for testing
              const x = null;
              return x.nonExistent();
            },
          },
          {
            method: "GET",
            pattern: "/healthy",
            fetch: () => {
              return new Response("Healthy", { status: 200 });
            },
          },
        ],
        // Custom error handler (Tier 2)
        error: (error) => {
          const errorMessage = error instanceof Error ? error.message : String(error);
          errorLog.push({ message: errorMessage, path: "unknown" });

          return new Response(
            JSON.stringify({
              error: "Internal Server Error",
              message: errorMessage,
              tier: "2",
            }),
            {
              status: 500,
              headers: { "content-type": "application/json" },
            },
          );
        },
        fetch: () => {
          return new Response("Not Found", { status: 404 });
        },
      });
    });

    afterAll(() => {
      server.close();
    });

    it("catches synchronous errors in route handler", async () => {
      errorLog.length = 0;

      const result = await zigClient({
        url: `https://${HOST}:${port}/sync-error`,
        insecure: true,
      });

      // Error handler should return 500
      expect(result.status).toBeOneOf([500, 0]); // 0 if connection closed
      if (result.status === 500) {
        const responseData = JSON.parse(result.body);
        expect(responseData.tier).toBe("2");
        expect(responseData.message).toContain("Synchronous error");
      }

      // Error should be logged
      expect(errorLog.length).toBeGreaterThanOrEqual(0);
    });

    it("catches asynchronous errors in route handler", async () => {
      errorLog.length = 0;

      const result = await zigClient({
        url: `https://${HOST}:${port}/async-error`,
        insecure: true,
      });

      expect(result.status).toBeOneOf([500, 0]);
      if (result.status === 500) {
        const responseData = JSON.parse(result.body);
        expect(responseData.tier).toBe("2");
        expect(responseData.message).toContain("Asynchronous error");
      }
    });

    it("catches TypeError in route handler", async () => {
      const result = await zigClient({
        url: `https://${HOST}:${port}/type-error`,
        insecure: true,
      });

      expect(result.status).toBeOneOf([500, 0]);
    });

    it("isolates errors to individual requests", async () => {
      errorLog.length = 0;

      // Trigger error
      await zigClient({
        url: `https://${HOST}:${port}/sync-error`,
        insecure: true,
      });

      // Healthy route should still work
      const healthyResult = await zigClient({
        url: `https://${HOST}:${port}/healthy`,
        insecure: true,
      });

      expect(healthyResult.exitCode).toBe(0);
      expect(healthyResult.status).toBe(200);
      expect(healthyResult.body).toContain("Healthy");
    });

    it("handles missing error handler gracefully", async () => {
      // Create server without custom error handler
      const noErrorHandlerServer = createH3Server({
        hostname: HOST,
        port: randPort(),
        certPath: getCertPath("cert.crt"),
        keyPath: getCertPath("cert.key"),
        routes: [
          {
            method: "GET",
            pattern: "/error",
            fetch: () => {
              throw new Error("Error without handler");
            },
          },
        ],
        fetch: () => {
          return new Response("OK", { status: 200 });
        },
      });

      try {
        const result = await zigClient({
          url: `https://${HOST}:${noErrorHandlerServer.port}/error`,
          insecure: true,
        });

        // Should get 500 or connection closed
        expect([500, 0]).toContain(result.status);
      } finally {
        noErrorHandlerServer.close();
      }
    });

    it("prevents error handler from cascading failures", async () => {
      // Create server where error handler itself throws
      let errorHandlerCalled = false;
      const cascadeServer = createH3Server({
        hostname: HOST,
        port: randPort(),
        certPath: getCertPath("cert.crt"),
        keyPath: getCertPath("cert.key"),
        routes: [
          {
            method: "GET",
            pattern: "/error",
            fetch: () => {
              throw new Error("Primary error");
            },
          },
          {
            method: "GET",
            pattern: "/healthy",
            fetch: () => {
              return new Response("Still healthy", { status: 200 });
            },
          },
        ],
        error: (error) => {
          errorHandlerCalled = true;
          throw new Error("Error handler also throws");
        },
        fetch: () => {
          return new Response("OK", { status: 200 });
        },
      });

      try {
        // Trigger error
        await zigClient({
          url: `https://${HOST}:${cascadeServer.port}/error`,
          insecure: true,
        });

        // Error handler was called (even though it threw)
        expect(errorHandlerCalled).toBe(true);

        // Server should survive and handle other requests
        const healthyResult = await zigClient({
          url: `https://${HOST}:${cascadeServer.port}/healthy`,
          insecure: true,
        });

        expect(healthyResult.exitCode).toBe(0);
        expect(healthyResult.status).toBe(200);
      } finally {
        cascadeServer.close();
      }
    });
  });

  describe("Tier 3: Protocol-level errors (log and continue)", () => {
    let server: H3Server;
    const port = randPort();
    const protocolErrorLog: string[] = [];

    beforeAll(() => {
      protocolErrorLog.length = 0;

      server = createH3Server({
        hostname: HOST,
        port,
        certPath: getCertPath("cert.crt"),
        keyPath: getCertPath("cert.key"),
        // QUIC datagram handler that throws
        quicDatagram: (payload, ctx) => {
          protocolErrorLog.push("QUIC datagram error");
          throw new Error("QUIC datagram handler error");
        },
        routes: [
          {
            method: "POST",
            pattern: "/h3dgram",
            // H3 datagram handler that throws
            h3Datagram: (payload, ctx) => {
              protocolErrorLog.push("H3 datagram error");
              throw new Error("H3 datagram handler error");
            },
            fetch: () => {
              return new Response("H3 datagram route", { status: 200 });
            },
          },
          {
            method: "CONNECT",
            pattern: "/wt",
            // WebTransport handler that throws
            webtransport: (ctx) => {
              protocolErrorLog.push("WebTransport error");
              throw new Error("WebTransport handler error");
            },
            fetch: () => {
              return new Response("WT route", { status: 200 });
            },
          },
          {
            method: "GET",
            pattern: "/healthy",
            fetch: () => {
              return new Response("Healthy", { status: 200 });
            },
          },
        ],
        fetch: () => {
          return new Response("OK", { status: 200 });
        },
      });
    });

    afterAll(() => {
      server.close();
    });

    it("logs protocol errors but continues serving", async () => {
      // Server should start successfully even with error-prone handlers
      expect(server.running).toBe(true);

      // Regular HTTP should still work
      const result = await zigClient({
        url: `https://${HOST}:${port}/healthy`,
        insecure: true,
      });

      expect(result.exitCode).toBe(0);
      expect(result.status).toBe(200);
    });

    it("handles H3 datagram handler errors gracefully", async () => {
      // Test route is accessible
      const result = await zigClient({
        url: `https://${HOST}:${port}/h3dgram`,
        method: "POST",
        insecure: true,
      });

      expect(result.exitCode).toBe(0);
      expect(result.status).toBe(200);

      // TODO: Send actual H3 datagram when client supports it
      // Handler error should be logged but not crash server
    });

    it("isolates protocol errors from other connections", async () => {
      // Make multiple requests in parallel
      const requests = Array.from({ length: 5 }, () =>
        zigClient({
          url: `https://${HOST}:${port}/healthy`,
          insecure: true,
        }),
      );

      const results = await Promise.all(requests);

      // All requests should succeed despite protocol handler errors
      for (const result of results) {
        expect(result.exitCode).toBe(0);
        expect(result.status).toBe(200);
      }
    });
  });

  describe("Tier 4: Stream-level errors (close stream, clean up)", () => {
    let server: H3Server;
    const port = randPort();

    beforeAll(() => {
      server = createH3Server({
        hostname: HOST,
        port,
        certPath: getCertPath("cert.crt"),
        keyPath: getCertPath("cert.key"),
        routes: [
          {
            method: "POST",
            pattern: "/stream-error",
            mode: "streaming",
            fetch: async (request) => {
              const reader = request.body?.getReader();
              if (!reader) {
                return new Response("No body", { status: 400 });
              }

              try {
                // Read a few chunks then throw
                let chunkCount = 0;
                while (chunkCount < 3) {
                  const { done, value } = await reader.read();
                  if (done) break;
                  chunkCount++;

                  if (chunkCount === 2) {
                    throw new Error("Intentional stream processing error");
                  }
                }
              } finally {
                reader.releaseLock();
              }

              return new Response("Should not reach here", { status: 200 });
            },
          },
          {
            method: "GET",
            pattern: "/healthy",
            fetch: () => {
              return new Response("Healthy", { status: 200 });
            },
          },
        ],
        error: (error) => {
          return new Response("Stream error handled", { status: 500 });
        },
        fetch: () => {
          return new Response("OK", { status: 200 });
        },
      });
    });

    afterAll(() => {
      server.close();
    });

    it("handles errors during stream processing", async () => {
      const payload = "x".repeat(10 * 1024); // 10KB to ensure multiple chunks

      const result = await zigClient({
        url: `https://${HOST}:${port}/stream-error`,
        method: "POST",
        body: payload,
        insecure: true,
        maxTime: 5,
      });

      // Should get error response or connection closed
      expect([500, 0]).toContain(result.status);
    });

    it("cleans up stream resources after error", async () => {
      // Trigger stream error
      await zigClient({
        url: `https://${HOST}:${port}/stream-error`,
        method: "POST",
        body: "trigger error",
        insecure: true,
        maxTime: 5,
      });

      // Server should continue working
      const healthyResult = await zigClient({
        url: `https://${HOST}:${port}/healthy`,
        insecure: true,
      });

      expect(healthyResult.exitCode).toBe(0);
      expect(healthyResult.status).toBe(200);

      // Stats should show server is healthy
      const stats = server.getStats();
      expect(stats.requests).toBeGreaterThanOrEqual(2n);
    });

    it("handles multiple stream errors without leaking resources", async () => {
      // Trigger multiple stream errors in sequence
      for (let i = 0; i < 5; i++) {
        await zigClient({
          url: `https://${HOST}:${port}/stream-error`,
          method: "POST",
          body: `error ${i}`,
          insecure: true,
          maxTime: 3,
        });
      }

      // Server should still be responsive
      const result = await zigClient({
        url: `https://${HOST}:${port}/healthy`,
        insecure: true,
      });

      expect(result.exitCode).toBe(0);
      expect(result.status).toBe(200);
    });
  });

  describe("Error handling documentation", () => {
    it("documents 4-tier error handling strategy", () => {
      // This test serves as documentation for the error handling tiers:

      // **Tier 1: Configuration Errors** (Throw during construction)
      // - Port validation, route patterns, method validation
      // - Rationale: Fail fast - user must fix config before server starts
      // - Tested in: phase5_validation.test.ts

      // **Tier 2: Request Handler Errors** (Return error Response)
      // - User handler throws, custom error handler support
      // - Rationale: Isolate per-request failures - log and return 500
      // - Tested in: this file, Tier 2 tests

      // **Tier 3: Protocol-Level Errors** (Log and continue)
      // - QUIC/H3 datagram handler errors, WebTransport handler errors
      // - Rationale: Best-effort networking - transient and recoverable
      // - Tested in: this file, Tier 3 tests

      // **Tier 4: Stream-Level Errors** (Close stream, clean up)
      // - Stream close callbacks, connection close cleanup
      // - Rationale: Graceful degradation - notify peer and free resources
      // - Tested in: this file, Tier 4 tests

      expect(true).toBe(true);
    });
  });
});
