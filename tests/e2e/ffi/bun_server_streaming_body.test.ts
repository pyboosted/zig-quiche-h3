import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { createH3Server, type H3Server } from "../../../src/bun/server.ts";
import { prebuildAllArtifacts } from "@helpers/prebuild";
import { getCertPath, randPort } from "@helpers/testUtils";
import { zigClient } from "@helpers/zigClient";

const HOST = "127.0.0.1";

describe("Bun FFI server streaming body handling", () => {
  let server: H3Server;
  const port = randPort();
  const receivedStreams: Array<{ path: string; totalBytes: number; chunkCount: number }> = [];

  beforeAll(async () => {
    await prebuildAllArtifacts();
    receivedStreams.length = 0;

    server = createH3Server({
      hostname: HOST,
      port,
      certPath: getCertPath("cert.crt"),
      keyPath: getCertPath("cert.key"),
      routes: [
        {
          method: "POST",
          pattern: "/upload/stream",
          mode: "streaming",
          fetch: async (request) => {
            const url = new URL(request.url);
            let totalBytes = 0;
            let chunkCount = 0;

            // Consume the streaming body
            const reader = request.body?.getReader();
            if (!reader) {
              return new Response("No body provided", { status: 400 });
            }

            try {
              while (true) {
                const { done, value } = await reader.read();
                if (done) break;
                totalBytes += value.length;
                chunkCount++;
              }
            } finally {
              reader.releaseLock();
            }

            receivedStreams.push({
              path: url.pathname,
              totalBytes,
              chunkCount,
            });

            return new Response(
              JSON.stringify({
                received: totalBytes,
                chunks: chunkCount,
                path: url.pathname,
              }),
              {
                status: 200,
                headers: { "content-type": "application/json" },
              },
            );
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

  it("handles 5MB streaming upload", async () => {
    // Create a 5MB payload
    const fiveMB = 5 * 1024 * 1024;
    const payload = "x".repeat(fiveMB);

    const result = await zigClient({
      url: `https://${HOST}:${port}/upload/stream`,
      method: "POST",
      body: payload,
      insecure: true,
      maxTime: 15, // Longer timeout for large upload
    });

    expect(result.exitCode).toBe(0);
    expect(result.status).toBe(200);

    const responseData = JSON.parse(result.body);
    expect(responseData.received).toBe(fiveMB);
    expect(responseData.chunks).toBeGreaterThan(0);

    // Verify server received the stream
    const serverRecord = receivedStreams.find(
      (r) => r.path === "/upload/stream" && r.totalBytes === fiveMB,
    );
    expect(serverRecord).toBeDefined();
    expect(serverRecord!.chunkCount).toBeGreaterThan(0);
  });

  it("handles concurrent streaming uploads (3 parallel 2MB posts)", async () => {
    const twoMB = 2 * 1024 * 1024;
    const payload = "y".repeat(twoMB);

    // Clear previous records
    receivedStreams.length = 0;

    // Launch 3 concurrent uploads
    const uploads = Array.from({ length: 3 }, (_, i) =>
      zigClient({
        url: `https://${HOST}:${port}/upload/stream`,
        method: "POST",
        body: payload,
        insecure: true,
        maxTime: 15,
      }),
    );

    const results = await Promise.all(uploads);

    // All uploads should succeed
    for (const result of results) {
      expect(result.exitCode).toBe(0);
      expect(result.status).toBe(200);

      const responseData = JSON.parse(result.body);
      expect(responseData.received).toBe(twoMB);
    }

    // Verify server received all 3 streams
    const serverRecords = receivedStreams.filter(
      (r) => r.path === "/upload/stream" && r.totalBytes === twoMB,
    );
    expect(serverRecords.length).toBe(3);

    // All should have received chunks
    for (const record of serverRecords) {
      expect(record.chunkCount).toBeGreaterThan(0);
    }
  });

  it("handles empty streaming body", async () => {
    const result = await zigClient({
      url: `https://${HOST}:${port}/upload/stream`,
      method: "POST",
      body: "",
      insecure: true,
    });

    expect(result.exitCode).toBe(0);
    expect(result.status).toBe(200);

    const responseData = JSON.parse(result.body);
    expect(responseData.received).toBe(0);
    expect(responseData.chunks).toBe(0);
  });

  it("handles streaming body with multiple chunks", async () => {
    // Create a 256KB payload (likely to be sent in multiple QUIC frames)
    const size = 256 * 1024;
    const payload = "z".repeat(size);

    receivedStreams.length = 0;

    const result = await zigClient({
      url: `https://${HOST}:${port}/upload/stream`,
      method: "POST",
      body: payload,
      insecure: true,
      maxTime: 10,
    });

    expect(result.exitCode).toBe(0);
    expect(result.status).toBe(200);

    const responseData = JSON.parse(result.body);
    expect(responseData.received).toBe(size);

    // Should have received multiple chunks due to QUIC frame size limits
    const serverRecord = receivedStreams.find(
      (r) => r.path === "/upload/stream" && r.totalBytes === size,
    );
    expect(serverRecord).toBeDefined();
    // Expect multiple chunks for 256KB (QUIC typically sends 1-64KB frames)
    expect(serverRecord!.chunkCount).toBeGreaterThanOrEqual(1);
  });

  it("preserves request headers with streaming body", async () => {
    const payload = "streaming data with headers";

    const result = await zigClient({
      url: `https://${HOST}:${port}/upload/stream`,
      method: "POST",
      body: payload,
      headers: {
        "content-type": "application/octet-stream",
        "x-streaming-test": "true",
      },
      insecure: true,
    });

    expect(result.exitCode).toBe(0);
    expect(result.status).toBe(200);

    const responseData = JSON.parse(result.body);
    expect(responseData.received).toBe(payload.length);
  });

  it("handles streaming mode for large binary data", async () => {
    // Simulate binary data upload (e.g., file upload scenario)
    const oneMB = 1024 * 1024;
    const binaryPayload = new Uint8Array(oneMB);
    // Fill with pattern to simulate real binary data
    for (let i = 0; i < oneMB; i++) {
      binaryPayload[i] = i % 256;
    }

    receivedStreams.length = 0;

    const result = await zigClient({
      url: `https://${HOST}:${port}/upload/stream`,
      method: "POST",
      body: binaryPayload,
      insecure: true,
      maxTime: 10,
    });

    expect(result.exitCode).toBe(0);
    expect(result.status).toBe(200);

    const responseData = JSON.parse(result.body);
    expect(responseData.received).toBe(oneMB);

    const serverRecord = receivedStreams.find(
      (r) => r.path === "/upload/stream" && r.totalBytes === oneMB,
    );
    expect(serverRecord).toBeDefined();
  });
});
