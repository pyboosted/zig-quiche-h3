import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { createH3Server, type H3Server } from "../../../src/bun/server.ts";
import { prebuildAllArtifacts } from "@helpers/prebuild";
import { getCertPath, randPort } from "@helpers/testUtils";
import { zigClient } from "@helpers/zigClient";
import { writeFile, unlink } from "fs/promises";
import { join } from "path";

const HOST = "127.0.0.1";
const TEST_FILE_PATH = join(import.meta.dir, "test-response-file.txt");
const TEST_FILE_CONTENT = "Hello from Bun.file()!\nThis is a test file for response bodies.";

describe("Bun FFI server response types", () => {
  let server: H3Server;
  const port = randPort();

  beforeAll(async () => {
    await prebuildAllArtifacts();
    // Create test file for Bun.file() test
    await writeFile(TEST_FILE_PATH, TEST_FILE_CONTENT, "utf-8");

    server = createH3Server({
      hostname: HOST,
      port,
      certPath: getCertPath("cert.crt"),
      keyPath: getCertPath("cert.key"),
      enableDatagram: false,
      fetch: async (request) => {
        const url = new URL(request.url);

        // Test Bun.file() response
        if (url.pathname === "/file") {
          return new Response(Bun.file(TEST_FILE_PATH), {
            headers: {
              "content-type": "text/plain; charset=utf-8",
            },
          });
        }

        // Test async iterator response (async generator)
        if (url.pathname === "/async-iterator") {
          async function* generateChunks() {
            const encoder = new TextEncoder();
            const chunks = ["chunk1\n", "chunk2\n", "chunk3\n"];
            for (const chunk of chunks) {
              yield encoder.encode(chunk);
              // Simulate async delay
              await new Promise((resolve) => setTimeout(resolve, 10));
            }
          }

          // Convert async generator to ReadableStream
          const stream = new ReadableStream({
            async start(controller) {
              for await (const chunk of generateChunks()) {
                controller.enqueue(chunk);
              }
              controller.close();
            },
          });

          return new Response(stream, {
            headers: {
              "content-type": "text/plain; charset=utf-8",
            },
          });
        }

        // Test empty body response
        if (url.pathname === "/empty") {
          return new Response(null, {
            status: 204,
            headers: {
              "x-test": "empty-body",
            },
          });
        }

        // Test forceful shutdown endpoint
        if (url.pathname === "/shutdown") {
          return new Response("Shutting down forcefully", {
            status: 200,
          });
        }

        return new Response("Not Found", { status: 404 });
      },
    });
  });

  afterAll(async () => {
    if (server) {
      server.stop();
      server.close();
    }
    // Clean up test file
    try {
      await unlink(TEST_FILE_PATH);
    } catch {
      // File might not exist
    }
  });

  it("should serve Bun.file() response bodies", async () => {
    const result = await zigClient({
      url: `https://${HOST}:${port}/file`,
      insecure: true,
    });

    expect(result.exitCode).toBe(0);
    expect(result.status).toBe(200);
    expect(result.headers["content-type"]).toBe("text/plain; charset=utf-8");
    expect(result.body).toBe(TEST_FILE_CONTENT);
  });

  it("should serve async iterator response bodies", async () => {
    const result = await zigClient({
      url: `https://${HOST}:${port}/async-iterator`,
      insecure: true,
    });

    expect(result.exitCode).toBe(0);
    expect(result.status).toBe(200);
    expect(result.headers["content-type"]).toBe("text/plain; charset=utf-8");
    expect(result.body).toBe("chunk1\nchunk2\nchunk3\n");
  });

  it("should handle empty body responses", async () => {
    const result = await zigClient({
      url: `https://${HOST}:${port}/empty`,
      insecure: true,
    });

    expect(result.exitCode).toBe(0);
    expect(result.status).toBe(204);
    expect(result.headers["x-test"]).toBe("empty-body");
    expect(result.body).toBe("");
  });

  it("should support forceful shutdown", async () => {
    // First make a request to verify server is responsive
    const result = await zigClient({
      url: `https://${HOST}:${port}/shutdown`,
      insecure: true,
    });

    expect(result.exitCode).toBe(0);
    expect(result.status).toBe(200);

    // Test forceful shutdown (stop with force=true)
    expect(() => server.stop(true)).not.toThrow();
    expect(server.running).toBe(false);

    // Restart server for cleanup
    server.start();
    expect(server.running).toBe(true);
  });

  it("should support graceful shutdown (default)", async () => {
    // Test graceful shutdown (stop with no args or force=false)
    expect(() => server.stop()).not.toThrow();
    expect(server.running).toBe(false);

    // Verify stop is idempotent
    expect(() => server.stop()).not.toThrow();
    expect(server.running).toBe(false);
  });
});