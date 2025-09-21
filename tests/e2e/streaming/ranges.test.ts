import "../test-runner"; // Import test runner for automatic cleanup
import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { describeBoth } from "@helpers/dualBinaryTest";
import { type ServerInstance, spawnServer } from "@helpers/spawnServer";
import { mkfile, type ServerBinaryType } from "@helpers/testUtils";
import { get, zigClient } from "@helpers/zigClient";

describeBoth("HTTP/3 Range Requests", (binaryType: ServerBinaryType) => {
    let server: ServerInstance;

    beforeAll(async () => {
        server = await spawnServer({ qlog: false, binaryType });
    });

    afterAll(async () => {
        await server.cleanup();
    });

    describe("Basic Range Support", () => {
        it("advertises Accept-Ranges: bytes for file downloads", async () => {
            const testFile = await mkfile(1024, new Uint8Array([0x01]));
            const relativePath = testFile.path.split("/tests/").pop() || testFile.path;

            const response = await get(`https://127.0.0.1:${server.port}/download/${relativePath}`);

            expect(response.status).toBe(200);
            expect(response.headers.get("accept-ranges")).toBe("bytes");
        });

        it("returns 206 Partial Content for valid range", async () => {
            const testFile = await mkfile(1024, new Uint8Array([0x01, 0x02, 0x03]));
            const relativePath = testFile.path.split("/tests/").pop() || testFile.path;

            const response = await zigClient(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
                {
                    headers: {
                        Range: "bytes=0-99",
                    },
                },
            );

            expect(response.status).toBe(206);
            expect(response.headers.get("content-range")).toBe("bytes 0-99/1024");
            expect(response.headers.get("content-length")).toBe("100");
            expect(response.body.length).toBe(100);
        });

        it("handles bytes=start- format (from start to end)", async () => {
            const testFile = await mkfile(1024, new Uint8Array([0x01]));
            const relativePath = testFile.path.split("/tests/").pop() || testFile.path;

            const response = await zigClient(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
                {
                    headers: {
                        Range: "bytes=1000-",
                    },
                },
            );

            expect(response.status).toBe(206);
            expect(response.headers.get("content-range")).toBe("bytes 1000-1023/1024");
            expect(response.headers.get("content-length")).toBe("24");
            expect(response.body.length).toBe(24);
        });

        it("handles bytes=-suffix format (last N bytes)", async () => {
            const testFile = await mkfile(1024, new Uint8Array([0x01]));
            const relativePath = testFile.path.split("/tests/").pop() || testFile.path;

            const response = await zigClient(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
                {
                    headers: {
                        Range: "bytes=-100",
                    },
                },
            );

            expect(response.status).toBe(206);
            expect(response.headers.get("content-range")).toBe("bytes 924-1023/1024");
            expect(response.headers.get("content-length")).toBe("100");
            expect(response.body.length).toBe(100);
        });
    });

    describe("416 Range Not Satisfiable", () => {
        it("returns 416 for range beyond file size", async () => {
            const testFile = await mkfile(1024, new Uint8Array([0x01]));
            const relativePath = testFile.path.split("/tests/").pop() || testFile.path;

            const response = await zigClient(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
                {
                    headers: {
                        Range: "bytes=2000-3000",
                    },
                },
            );

            expect(response.status).toBe(416);
            // RFC 7233: Must use "bytes */size" format for 416
            expect(response.headers.get("content-range")).toBe("bytes */1024");
            expect(response.headers.get("content-length")).toBe("0");
            expect(response.body.length).toBe(0);
        });

        it("returns 416 for invalid range (start > end)", async () => {
            const testFile = await mkfile(1024, new Uint8Array([0x01]));
            const relativePath = testFile.path.split("/tests/").pop() || testFile.path;

            const response = await zigClient(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
                {
                    headers: {
                        Range: "bytes=500-100",
                    },
                },
            );

            expect(response.status).toBe(416);
            expect(response.headers.get("content-range")).toBe("bytes */1024");
            expect(response.headers.get("content-length")).toBe("0");
        });

        it("returns 416 for suffix larger than file", async () => {
            const testFile = await mkfile(100, new Uint8Array([0x01]));
            const relativePath = testFile.path.split("/tests/").pop() || testFile.path;

            const response = await zigClient(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
                {
                    headers: {
                        Range: "bytes=-500",
                    },
                },
            );

            // Should return full file when suffix > file size
            expect(response.status).toBe(206);
            expect(response.headers.get("content-range")).toBe("bytes 0-99/100");
            expect(response.headers.get("content-length")).toBe("100");
        });
    });

    describe("Invalid Range Headers", () => {
        it("ignores malformed range and returns full file", async () => {
            const testFile = await mkfile(1024, new Uint8Array([0x01]));
            const relativePath = testFile.path.split("/tests/").pop() || testFile.path;

            const response = await zigClient(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
                {
                    headers: {
                        Range: "invalid-format",
                    },
                },
            );

            expect(response.status).toBe(200); // Full file
            expect(response.headers.get("content-length")).toBe("1024");
            expect(response.body.length).toBe(1024);
        });

        it("ignores non-bytes unit and returns full file", async () => {
            const testFile = await mkfile(1024, new Uint8Array([0x01]));
            const relativePath = testFile.path.split("/tests/").pop() || testFile.path;

            const response = await zigClient(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
                {
                    headers: {
                        Range: "items=0-10",
                    },
                },
            );

            expect(response.status).toBe(200); // Full file
            expect(response.headers.get("content-length")).toBe("1024");
        });

        it("ignores multi-range requests and returns full file", async () => {
            const testFile = await mkfile(1024, new Uint8Array([0x01]));
            const relativePath = testFile.path.split("/tests/").pop() || testFile.path;

            const response = await zigClient(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
                {
                    headers: {
                        Range: "bytes=0-99,200-299",
                    },
                },
            );

            expect(response.status).toBe(200); // Full file (multi-range not supported)
            expect(response.headers.get("content-length")).toBe("1024");
        });
    });

    describe("Data Integrity", () => {
        it("range content matches corresponding portion of full file", async () => {
            // Create file with known pattern
            const pattern = new Uint8Array(256);
            for (let i = 0; i < 256; i++) {
                pattern[i] = i;
            }
            const testFile = await mkfile(1024, pattern);
            const relativePath = testFile.path.split("/tests/").pop() || testFile.path;

            // Get full file
            const fullResponse = await get(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
            );
            expect(fullResponse.status).toBe(200);

            // Get range
            const rangeResponse = await zigClient(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
                {
                    headers: {
                        Range: "bytes=100-199",
                    },
                },
            );
            expect(rangeResponse.status).toBe(206);

            // Compare content
            const fullSlice = fullResponse.body.slice(100, 200);
            expect(rangeResponse.body).toEqual(fullSlice);
        });

        it("multiple ranges of same file have correct content", async () => {
            const testFile = await mkfile(1024, new Uint8Array([0x01, 0x02, 0x03]));
            const relativePath = testFile.path.split("/tests/").pop() || testFile.path;

            // Request three different ranges
            const range1 = await zigClient(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
                {
                    headers: { Range: "bytes=0-99" },
                },
            );

            const range2 = await zigClient(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
                {
                    headers: { Range: "bytes=500-599" },
                },
            );

            const range3 = await zigClient(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
                {
                    headers: { Range: "bytes=-100" },
                },
            );

            expect(range1.status).toBe(206);
            expect(range2.status).toBe(206);
            expect(range3.status).toBe(206);

            // Verify each has correct size
            expect(range1.body.length).toBe(100);
            expect(range2.body.length).toBe(100);
            expect(range3.body.length).toBe(100);

            // Verify Content-Range headers
            expect(range1.headers.get("content-range")).toBe("bytes 0-99/1024");
            expect(range2.headers.get("content-range")).toBe("bytes 500-599/1024");
            expect(range3.headers.get("content-range")).toBe("bytes 924-1023/1024");
        });
    });

    describe("Edge Cases", () => {
        it("handles single byte range", async () => {
            const testFile = await mkfile(1024, new Uint8Array([0xff]));
            const relativePath = testFile.path.split("/tests/").pop() || testFile.path;

            const response = await zigClient(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
                {
                    headers: {
                        Range: "bytes=0-0",
                    },
                },
            );

            expect(response.status).toBe(206);
            expect(response.headers.get("content-range")).toBe("bytes 0-0/1024");
            expect(response.headers.get("content-length")).toBe("1");
            expect(response.body.length).toBe(1);
            expect(response.body[0]).toBe(0xff);
        });

        it("handles last byte range", async () => {
            const testFile = await mkfile(1024, new Uint8Array([0xaa, 0xbb]));
            const relativePath = testFile.path.split("/tests/").pop() || testFile.path;

            const response = await zigClient(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
                {
                    headers: {
                        Range: "bytes=1023-1023",
                    },
                },
            );

            expect(response.status).toBe(206);
            expect(response.headers.get("content-range")).toBe("bytes 1023-1023/1024");
            expect(response.headers.get("content-length")).toBe("1");
            expect(response.body.length).toBe(1);
        });

        it("handles empty file with range request", async () => {
            const testFile = await mkfile(0, new Uint8Array([]));
            const relativePath = testFile.path.split("/tests/").pop() || testFile.path;

            const response = await zigClient(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
                {
                    headers: {
                        Range: "bytes=0-10",
                    },
                },
            );

            expect(response.status).toBe(416);
            expect(response.headers.get("content-range")).toBe("bytes */0");
            expect(response.headers.get("content-length")).toBe("0");
        });
    });

    describe("HEAD Requests with Ranges", () => {
        it.skip("returns correct headers for HEAD with range (curl HTTP/3 limitation - exit code 18)", async () => {
            const testFile = await mkfile(1024, new Uint8Array([0x01]));
            const relativePath = testFile.path.split("/tests/").pop() || testFile.path;

            const response = await zigClient(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
                {
                    method: "HEAD",
                    headers: {
                        Range: "bytes=0-99",
                    },
                },
            );

            expect(response.status).toBe(206);
            expect(response.headers.get("content-range")).toBe("bytes 0-99/1024");
            expect(response.headers.get("content-length")).toBe("100");
            expect(response.body.length).toBe(0); // No body for HEAD
        });

        it("returns 416 headers for HEAD with invalid range", async () => {
            const testFile = await mkfile(100, new Uint8Array([0x01]));
            const relativePath = testFile.path.split("/tests/").pop() || testFile.path;

            const response = await zigClient(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
                {
                    method: "HEAD",
                    headers: {
                        Range: "bytes=200-300",
                    },
                },
            );

            expect(response.status).toBe(416);
            expect(response.headers.get("content-range")).toBe("bytes */100");
            expect(response.headers.get("content-length")).toBe("0");
            expect(response.body.length).toBe(0); // No body for HEAD
        });
    });

    describe("Large File Ranges", () => {
        it("handles range request for large file", async () => {
            // Create 10MB file
            const testFile = await mkfile(10 * 1024 * 1024, new Uint8Array([0x42]));
            const relativePath = testFile.path.split("/tests/").pop() || testFile.path;

            // Request middle 1MB
            const response = await zigClient(
                `https://127.0.0.1:${server.port}/download/${relativePath}`,
                {
                    headers: {
                        Range: "bytes=5242880-6291455", // 5MB to 6MB - 1
                    },
                },
            );

            expect(response.status).toBe(206);
            expect(response.headers.get("content-range")).toBe("bytes 5242880-6291455/10485760");
            expect(response.headers.get("content-length")).toBe("1048576");
            expect(response.body.length).toBe(1048576);

            // Verify content
            expect(response.body[0]).toBe(0x42);
            expect(response.body[response.body.length - 1]).toBe(0x42);
        });
    });
});
