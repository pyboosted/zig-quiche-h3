import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { createH3Server, type H3Server } from "../../../src/bun/server.ts";
import { prebuildAllArtifacts } from "@helpers/prebuild";
import { getCertPath, randPort } from "@helpers/testUtils";
import { zigClient } from "@helpers/zigClient";

const HOST = "127.0.0.1";

// Stress tests are gated behind H3_STRESS=1 environment variable
const isStressTest = process.env.H3_STRESS === "1";
const describeStress = isStressTest ? describe : describe.skip;

describeStress("Bun FFI server stress tests (H3_STRESS=1)", () => {
  let server: H3Server;
  const port = randPort();
  const requestCount = { buffered: 0, streaming: 0, datagram: 0 };

  beforeAll(async () => {
    await prebuildAllArtifacts();

    // Reset counters
    requestCount.buffered = 0;
    requestCount.streaming = 0;
    requestCount.datagram = 0;

    server = createH3Server({
      hostname: HOST,
      port,
      certPath: getCertPath("cert.crt"),
      keyPath: getCertPath("cert.key"),
      routes: [
        // Buffered mode endpoint
        {
          method: "POST",
          pattern: "/stress/buffered",
          mode: "buffered",
          fetch: async (request) => {
            const body = await request.text();
            requestCount.buffered++;
            return new Response(
              JSON.stringify({
                received: body.length,
                requestNumber: requestCount.buffered,
              }),
              {
                status: 200,
                headers: { "content-type": "application/json" },
              },
            );
          },
        },
        // Streaming mode endpoint
        {
          method: "POST",
          pattern: "/stress/streaming",
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
            requestCount.streaming++;
            return new Response(
              JSON.stringify({
                received: totalBytes,
                requestNumber: requestCount.streaming,
              }),
              {
                status: 200,
                headers: { "content-type": "application/json" },
              },
            );
          },
        },
        // H3 datagram endpoint
        {
          method: "POST",
          pattern: "/stress/datagram",
          h3Datagram: (payload, ctx) => {
            requestCount.datagram++;
            ctx.sendReply(payload);
          },
          fetch: async () => {
            return new Response("Datagram endpoint", { status: 200 });
          },
        },
        // Simple endpoint for baseline testing
        {
          method: "GET",
          pattern: "/stress/simple",
          fetch: async () => {
            return new Response("OK", { status: 200 });
          },
        },
      ],
      fetch: async () => {
        return new Response("Not Found", { status: 404 });
      },
    });

    console.log(`[Stress Test] Server started on port ${port}`);
  });

  afterAll(() => {
    console.log(
      `[Stress Test] Final counts - Buffered: ${requestCount.buffered}, Streaming: ${requestCount.streaming}, Datagrams: ${requestCount.datagram}`,
    );
    server.close();
  });

  it("handles 100+ concurrent simple GET requests", async () => {
    const concurrency = 100;
    console.log(`[Stress Test] Starting ${concurrency} concurrent GET requests...`);

    const startTime = Date.now();
    const requests = Array.from({ length: concurrency }, (_, i) =>
      zigClient({
        url: `https://${HOST}:${port}/stress/simple`,
        insecure: true,
        maxTime: 15,
      }),
    );

    const results = await Promise.all(requests);
    const endTime = Date.now();
    const duration = endTime - startTime;

    // All requests should succeed
    const successCount = results.filter((r) => r.exitCode === 0 && r.status === 200).length;
    expect(successCount).toBe(concurrency);

    console.log(
      `[Stress Test] Completed ${concurrency} requests in ${duration}ms (${(concurrency / (duration / 1000)).toFixed(2)} req/s)`,
    );
  }, 30000);

  it("handles 100+ concurrent buffered POST requests", async () => {
    const concurrency = 100;
    const payload = JSON.stringify({ data: "test".repeat(100) }); // ~500 bytes
    console.log(`[Stress Test] Starting ${concurrency} concurrent buffered POSTs...`);

    requestCount.buffered = 0;
    const startTime = Date.now();

    const requests = Array.from({ length: concurrency }, () =>
      zigClient({
        url: `https://${HOST}:${port}/stress/buffered`,
        method: "POST",
        body: payload,
        insecure: true,
        maxTime: 20,
      }),
    );

    const results = await Promise.all(requests);
    const endTime = Date.now();
    const duration = endTime - startTime;

    // All requests should succeed
    const successCount = results.filter((r) => r.exitCode === 0 && r.status === 200).length;
    expect(successCount).toBe(concurrency);

    console.log(
      `[Stress Test] Completed ${concurrency} buffered POSTs in ${duration}ms (${(concurrency / (duration / 1000)).toFixed(2)} req/s)`,
    );
    console.log(`[Stress Test] Server processed ${requestCount.buffered} buffered requests`);
  }, 40000);

  it("handles 10 parallel streaming uploads (2MB each)", async () => {
    const concurrency = 10;
    const twoMB = 2 * 1024 * 1024;
    const payload = "x".repeat(twoMB);
    console.log(
      `[Stress Test] Starting ${concurrency} parallel 2MB streaming uploads (${(concurrency * 2).toFixed(0)}MB total)...`,
    );

    requestCount.streaming = 0;
    const startTime = Date.now();

    const requests = Array.from({ length: concurrency }, (_, i) =>
      zigClient({
        url: `https://${HOST}:${port}/stress/streaming`,
        method: "POST",
        body: payload,
        insecure: true,
        maxTime: 30,
      }),
    );

    const results = await Promise.all(requests);
    const endTime = Date.now();
    const duration = endTime - startTime;

    // All uploads should succeed
    const successCount = results.filter((r) => r.exitCode === 0 && r.status === 200).length;
    expect(successCount).toBe(concurrency);

    // Verify all payloads were received fully
    for (const result of results) {
      if (result.exitCode === 0) {
        const responseData = JSON.parse(result.body);
        expect(responseData.received).toBe(twoMB);
      }
    }

    const totalMB = (concurrency * twoMB) / (1024 * 1024);
    const throughputMBps = totalMB / (duration / 1000);
    console.log(
      `[Stress Test] Completed ${concurrency} streaming uploads in ${duration}ms (${throughputMBps.toFixed(2)} MB/s)`,
    );
    console.log(`[Stress Test] Server processed ${requestCount.streaming} streaming requests`);
  }, 60000);

  it("handles H3 datagram burst (100+ datagrams)", async () => {
    const dgramCount = 100;
    const payload = "stress-test-datagram";
    console.log(`[Stress Test] Starting H3 datagram burst test (${dgramCount} datagrams)...`);

    requestCount.datagram = 0;
    const startTime = Date.now();

    // Send burst of datagrams via h3-client
    const result = await zigClient({
      url: `https://${HOST}:${port}/stress/datagram`,
      method: "POST",
      h3Dgram: true,
      dgramPayload: payload,
      dgramCount,
      dgramIntervalMs: 5, // 5ms between sends
      waitForDgrams: dgramCount,
      insecure: true,
      maxTime: 30,
    });

    const endTime = Date.now();
    const duration = endTime - startTime;

    expect(result.exitCode).toBe(0);
    expect(result.status).toBe(200);

    // Count datagram events in output
    const rawText = result.raw;
    const datagramEvents = rawText.match(/event=datagram/g);
    expect(datagramEvents).toBeTruthy();
    expect(datagramEvents!.length).toBeGreaterThanOrEqual(dgramCount * 0.9); // Allow 10% loss

    console.log(
      `[Stress Test] Completed datagram burst in ${duration}ms (${(dgramCount / (duration / 1000)).toFixed(0)} dgrams/s)`,
    );
    console.log(
      `[Stress Test] Received ${datagramEvents!.length}/${dgramCount} datagram echoes`,
    );
  }, 60000);

  it("handles mixed workload (concurrent requests + uploads + datagrams)", async () => {
    console.log("[Stress Test] Starting mixed workload test...");

    requestCount.buffered = 0;
    requestCount.streaming = 0;
    requestCount.datagram = 0;

    const startTime = Date.now();

    // Launch mixed workload
    const tasks = [
      // 20 simple GET requests
      ...Array.from({ length: 20 }, () =>
        zigClient({
          url: `https://${HOST}:${port}/stress/simple`,
          insecure: true,
          maxTime: 20,
        }),
      ),
      // 10 buffered POSTs
      ...Array.from({ length: 10 }, () =>
        zigClient({
          url: `https://${HOST}:${port}/stress/buffered`,
          method: "POST",
          body: "buffered data",
          insecure: true,
          maxTime: 20,
        }),
      ),
      // 5 streaming uploads (1MB each)
      ...Array.from({ length: 5 }, () =>
        zigClient({
          url: `https://${HOST}:${port}/stress/streaming`,
          method: "POST",
          body: "y".repeat(1024 * 1024),
          insecure: true,
          maxTime: 25,
        }),
      ),
      // 3 datagram bursts (50 datagrams each)
      ...Array.from({ length: 3 }, () =>
        zigClient({
          url: `https://${HOST}:${port}/stress/datagram`,
          method: "POST",
          h3Dgram: true,
          dgramPayload: "mixed-workload",
          dgramCount: 50,
          dgramIntervalMs: 10,
          waitForDgrams: 50,
          insecure: true,
          maxTime: 25,
        }),
      ),
    ];

    const results = await Promise.all(tasks);
    const endTime = Date.now();
    const duration = endTime - startTime;

    // Count successes
    const successCount = results.filter((r) => r.exitCode === 0 && r.status === 200).length;
    const totalTasks = tasks.length;

    console.log(
      `[Stress Test] Mixed workload completed: ${successCount}/${totalTasks} tasks succeeded in ${duration}ms`,
    );
    console.log(
      `[Stress Test] Server stats - Buffered: ${requestCount.buffered}, Streaming: ${requestCount.streaming}`,
    );

    // At least 90% of tasks should succeed (allow for some network variability)
    expect(successCount).toBeGreaterThanOrEqual(totalTasks * 0.9);
  }, 60000);

  it("maintains stability under sustained load (200 requests over 10 seconds)", async () => {
    console.log("[Stress Test] Starting sustained load test (200 requests over 10s)...");

    const totalRequests = 200;
    const durationMs = 10000;
    const intervalMs = durationMs / totalRequests;

    const startTime = Date.now();
    const results: Array<{ exitCode: number; status: number }> = [];

    // Send requests at steady rate
    for (let i = 0; i < totalRequests; i++) {
      const requestPromise = zigClient({
        url: `https://${HOST}:${port}/stress/simple`,
        insecure: true,
        maxTime: 5,
      }).then((result) => {
        results.push({ exitCode: result.exitCode, status: result.status });
      });

      // Don't await - let requests accumulate
      if (i < totalRequests - 1) {
        await new Promise((resolve) => setTimeout(resolve, intervalMs));
      }
    }

    // Wait for all requests to complete
    while (results.length < totalRequests) {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }

    const endTime = Date.now();
    const actualDuration = endTime - startTime;

    const successCount = results.filter((r) => r.exitCode === 0 && r.status === 200).length;

    console.log(
      `[Stress Test] Sustained load test completed: ${successCount}/${totalRequests} requests succeeded in ${actualDuration}ms`,
    );
    console.log(
      `[Stress Test] Average rate: ${(totalRequests / (actualDuration / 1000)).toFixed(2)} req/s`,
    );

    // At least 95% should succeed under sustained load
    expect(successCount).toBeGreaterThanOrEqual(totalRequests * 0.95);

    // Server should still be healthy
    const stats = server.getStats();
    expect(server.running).toBe(true);
    expect(stats.requests).toBeGreaterThanOrEqual(BigInt(totalRequests));
  }, 30000);

  it("recovers gracefully from connection churn", async () => {
    console.log(
      "[Stress Test] Starting connection churn test (rapid connect/disconnect)...",
    );

    const cycles = 50;
    let successCount = 0;

    for (let i = 0; i < cycles; i++) {
      // Make a request (establishes connection)
      const result = await zigClient({
        url: `https://${HOST}:${port}/stress/simple`,
        insecure: true,
        maxTime: 5,
      });

      if (result.exitCode === 0 && result.status === 200) {
        successCount++;
      }

      // Small delay before next connection
      await new Promise((resolve) => setTimeout(resolve, 20));
    }

    console.log(
      `[Stress Test] Connection churn test completed: ${successCount}/${cycles} requests succeeded`,
    );

    // At least 90% should succeed despite rapid connection churn
    expect(successCount).toBeGreaterThanOrEqual(cycles * 0.9);

    // Server should still be responsive
    const finalResult = await zigClient({
      url: `https://${HOST}:${port}/stress/simple`,
      insecure: true,
    });
    expect(finalResult.exitCode).toBe(0);
    expect(finalResult.status).toBe(200);
  }, 30000);
});

describe("Stress test documentation", () => {
  it("documents how to run stress tests", () => {
    // Stress tests are gated behind H3_STRESS=1 environment variable
    // to prevent them from running in CI by default (they're slow and resource-intensive)

    // To run stress tests:
    // H3_STRESS=1 bun test tests/e2e/ffi/bun_server_stress.test.ts

    // Or run all tests including stress:
    // H3_STRESS=1 bun test

    expect(true).toBe(true);
  });

  if (!isStressTest) {
    it("skips stress tests when H3_STRESS is not set", () => {
      console.log("[Info] Stress tests skipped. Set H3_STRESS=1 to run stress tests.");
      expect(process.env.H3_STRESS).not.toBe("1");
    });
  }
});
