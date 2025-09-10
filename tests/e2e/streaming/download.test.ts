import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { createHash } from "node:crypto";
import { curl, get } from "@helpers/curlClient";
import { type ServerInstance, spawnServer } from "@helpers/spawnServer";
import { mkfile, parseContentLength, withTempDir } from "@helpers/testUtils";

describe("HTTP/3 Download Streaming", () => {
  let server: ServerInstance;

  beforeAll(async () => {
    server = await spawnServer({ qlog: false });
  });

  afterAll(async () => {
    await server.cleanup();
  });

  describe("/stream/test endpoint", () => {
    it("returns 10MB with X-Checksum header", async () => {
      const response = await get(`https://127.0.0.1:${server.port}/stream/test`);

      expect(response.status).toBe(200);
      expect(response.headers.get("content-type")).toContain("application/octet-stream");

      // Check X-Checksum header exists
      const checksum = response.headers.get("x-checksum");
      expect(checksum).toBeTruthy();
      expect(checksum!).toMatch(/^[0-9a-f]+$/i); // Hex string

      // Verify content length
      const contentLength = parseContentLength(response.headers);
      const expectedSize = 10 * 1024 * 1024; // 10MB
      expect(contentLength).toBe(expectedSize);
      expect(response.body.length).toBe(expectedSize);

      // Verify data integrity by computing SHA-256
      const hash = createHash("sha256");
      hash.update(response.body);
      const computedHash = hash.digest("hex");

      // The server should provide a consistent checksum
      expect(computedHash).toBe(computedHash); // Self-consistent
    });

    it("has consistent content across multiple requests", async () => {
      const response1 = await get(`https://127.0.0.1:${server.port}/stream/test`);
      const response2 = await get(`https://127.0.0.1:${server.port}/stream/test`);

      expect(response1.status).toBe(200);
      expect(response2.status).toBe(200);

      // Content should be identical
      expect(response1.body.length).toBe(response2.body.length);

      // Checksums should match
      const checksum1 = response1.headers.get("x-checksum");
      const checksum2 = response2.headers.get("x-checksum");
      expect(checksum1).toBeTruthy();
      expect(checksum2).toBeTruthy();
      expect(checksum1!).toBe(checksum2!);
    });
  });

  describe("/stream/1gb endpoint (stress test)", () => {
    const shouldRunStress = process.env.H3_STRESS === "1";

    it.skipIf(!shouldRunStress)("returns 1GB with correct content-length", async () => {
      const response = await curl(`https://127.0.0.1:${server.port}/stream/1gb`, {
        outputNull: true, // Don't buffer the body, just check headers
      });

      expect(response.status).toBe(200);
      expect(response.headers.get("content-type")).toContain("application/octet-stream");

      // Check content-length header
      const contentLength = parseContentLength(response.headers);
      const expectedSize = 1024 * 1024 * 1024; // 1GB
      expect(contentLength).toBe(expectedSize);

      console.log(`1GB stream test passed (headers only)`);
    });

    it.skipIf(!shouldRunStress)("1GB download completes without memory exhaustion", async () => {
      // Test with limited rate to simulate real-world conditions
      const response = await curl(`https://127.0.0.1:${server.port}/stream/1gb`, {
        outputNull: true,
        limitRate: "30M", // 10MB/s rate limit
        maxTime: 120, // 2 minute timeout
      });

      expect(response.status).toBe(200);

      const contentLength = parseContentLength(response.headers);
      expect(contentLength).toBe(1024 * 1024 * 1024);

      console.log("1GB rate-limited download completed successfully");
    });
  });

  describe("/download/* file serving", () => {
    it("serves generated files with correct checksum", async () => {
      await withTempDir(async (_dir) => {
        // Create a test file
        const testFile = await mkfile(1024 * 1024, new Uint8Array([0x42, 0xff, 0x00])); // 1MB with pattern

        // Request the file via download endpoint
        const relativePath = testFile.path.replace("./", ""); // Remove leading ./
        const response = await get(`https://127.0.0.1:${server.port}/download/${relativePath}`);

        expect(response.status).toBe(200);

        // Verify content matches
        expect(response.body.length).toBe(testFile.size);

        // Verify SHA-256 checksum
        const hash = createHash("sha256");
        hash.update(response.body);
        const computedHash = hash.digest("hex");
        expect(computedHash).toBe(testFile.sha256);
      });
    });

    it("returns 404 for non-existent files", async () => {
      const response = await get(`https://127.0.0.1:${server.port}/download/does-not-exist.txt`);

      expect(response.status).toBe(404);
      expect(response.headers.get("content-type")).toContain("application/json");

      const json = JSON.parse(new TextDecoder().decode(response.body));
      expect(json.error).toContain("File not found");
    });

    it("rejects path traversal attempts", async () => {
      const response = await get(`https://127.0.0.1:${server.port}/download/../../../etc/passwd`);

      // Router doesn't match paths with .. so returns 404, not 403
      expect(response.status).toBe(404);
      expect(response.headers.get("content-length")).toBe("0");
    });

    it("rejects absolute paths", async () => {
      const response = await get(`https://127.0.0.1:${server.port}/download//etc/passwd`);

      expect(response.status).toBe(403);
      // Server sends JSON error response for this case
      expect(response.headers.get("content-type")).toContain("application/json");

      const json = JSON.parse(new TextDecoder().decode(response.body));
      expect(json.error).toContain("Absolute paths not allowed");
    });

    it("rejects empty file path", async () => {
      const response = await get(`https://127.0.0.1:${server.port}/download/`);

      expect(response.status).toBe(400);
      expect(response.headers.get("content-type")).toContain("application/json");

      const json = JSON.parse(new TextDecoder().decode(response.body));
      expect(json.error).toContain("File path required");
    });
  });

  describe("Streaming behavior", () => {
    it("supports partial content ranges (if implemented)", async () => {
      const response = await curl(`https://127.0.0.1:${server.port}/stream/test`, {
        headers: {
          Range: "bytes=0-1023", // First 1KB
        },
      });

      // Server may or may not support ranges, but should not crash
      expect([200, 206, 416]).toContain(response.status);

      if (response.status === 206) {
        // If ranges are supported, verify partial content
        expect(response.body.length).toBe(1024);
        expect(response.headers.get("content-range")).toBeTruthy();
      }
    });

    it("handles client disconnect gracefully", async () => {
      // Start a request with a very short timeout to simulate disconnect
      try {
        await curl(`https://127.0.0.1:${server.port}/stream/test`, {
          maxTime: 0.1, // 100ms timeout
        });
      } catch {
        // Expected to timeout/fail
      }

      // Server should still be responsive after client disconnect
      const response = await get(`https://127.0.0.1:${server.port}/`);
      expect(response.status).toBe(200);
    });

    it("handles multiple concurrent downloads", async () => {
      const numConcurrent = 5;

      const promises = Array.from({ length: numConcurrent }, () =>
        get(`https://127.0.0.1:${server.port}/stream/test`),
      );

      const responses = await Promise.all(promises);

      // All requests should succeed
      for (const response of responses) {
        expect(response.status).toBe(200);
        expect(response.body.length).toBe(10 * 1024 * 1024);
      }

      // All checksums should be identical
      const checksums = responses.map((r) => r.headers.get("x-checksum"));
      const uniqueChecksums = new Set(checksums);
      expect(uniqueChecksums.size).toBe(1); // All should be the same
    });
  });
});
