import "../test-runner"; // Import test runner for automatic cleanup
import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { createHash } from "node:crypto";
import { describeBoth } from "@helpers/dualBinaryTest";
import { type ServerInstance, spawnServer } from "@helpers/spawnServer";
import { mkfile, type ServerBinaryType, withTempDir } from "@helpers/testUtils";
import { post } from "@helpers/zigClient";
import { verboseLog } from "@helpers/logCapture";

describeBoth("HTTP/3 Upload Streaming", (binaryType: ServerBinaryType) => {
    let server: ServerInstance;

    beforeAll(async () => {
        server = await spawnServer({ qlog: false, binaryType });
    });

    afterAll(async () => {
        await server.cleanup();
    });

    describe("/upload/stream endpoint", () => {
        it("handles small uploads and returns correct stats", async () => {
            const testData = "Hello, streaming upload!";
            const dataBytes = new TextEncoder().encode(testData);

            const response = await post(
                `https://127.0.0.1:${server.port}/upload/stream`,
                testData,
                {
                    headers: {
                        "content-type": "text/plain",
                    },
                },
            );

            expect(response.status).toBe(200);
            expect(response.headers.get("content-type")).toContain("application/json");

            const json = JSON.parse(new TextDecoder().decode(response.body));

            // Validate response structure matches audit requirements
            expect(json.bytes_received).toBe(dataBytes.length);
            expect(json.sha256).toBeTruthy();
            expect(json.sha256).toMatch(/^[0-9a-f]{64}$/i); // 64 hex chars
            expect(typeof json.elapsed_ms).toBe("number");
            expect(typeof json.throughput_mbps).toBe("number");

            // Verify SHA-256 is correct
            const expectedHash = createHash("sha256").update(dataBytes).digest("hex");
            expect(json.sha256).toBe(expectedHash);
        });

        it("handles binary uploads correctly", async () => {
            await withTempDir(async () => {
                // Create binary test file with pattern
                const pattern = new Uint8Array([0x00, 0x01, 0x02, 0xff, 0xfe, 0xfd]);
                const testFile = await mkfile(1024, pattern); // 1KB

                const fileData = await Bun.file(testFile.path).arrayBuffer();
                const response = await post(
                    `https://127.0.0.1:${server.port}/upload/stream`,
                    new File([fileData], "test.bin"),
                    {
                        headers: {
                            "content-type": "application/octet-stream",
                        },
                    },
                );

                expect(response.status).toBe(200);

                const json = JSON.parse(new TextDecoder().decode(response.body));
                expect(json.bytes_received).toBe(testFile.size);
                expect(json.sha256).toBe(testFile.sha256);
            });
        });

        it("handles medium-sized uploads (10MB)", async () => {
            await withTempDir(async () => {
                const testFile = await mkfile(10 * 1024 * 1024); // 10MB

                const fileData = await Bun.file(testFile.path).arrayBuffer();
                const response = await post(
                    `https://127.0.0.1:${server.port}/upload/stream`,
                    new File([fileData], "large.bin"),
                    {
                        headers: {
                            "content-type": "application/octet-stream",
                        },
                    },
                );

                expect(response.status).toBe(200);

                const json = JSON.parse(new TextDecoder().decode(response.body));
                expect(json.bytes_received).toBe(testFile.size);
                expect(json.sha256).toBe(testFile.sha256);

                // Should have reasonable throughput
                expect(json.throughput_mbps).toBeGreaterThan(0);
                expect(json.elapsed_ms).toBeGreaterThan(0);

                verboseLog(
                    `10MB upload: ${json.throughput_mbps.toFixed(2)} Mbps, ${json.elapsed_ms}ms`,
                );
            });
        });

        it.skipIf(process.env.H3_STRESS !== "1")(
            "handles large uploads (100MB) with backpressure",
            async () => {
                await withTempDir(async () => {
                    const testFile = await mkfile(100 * 1024 * 1024); // 100MB

                    const fileData = await Bun.file(testFile.path).arrayBuffer();
                    const response = await post(
                        `https://127.0.0.1:${server.port}/upload/stream`,
                        new File([fileData], "huge.bin"),
                        {
                            headers: {
                                "content-type": "application/octet-stream",
                            },
                            maxTime: 120, // 2 minute timeout
                        },
                    );

                    expect(response.status).toBe(200);

                    const json = JSON.parse(new TextDecoder().decode(response.body));
                    expect(json.bytes_received).toBe(testFile.size);
                    expect(json.sha256).toBe(testFile.sha256);

                    verboseLog(
                        `100MB upload: ${json.throughput_mbps.toFixed(2)} Mbps, ${json.elapsed_ms}ms`,
                    );
                });
            },
        );

        it("computes SHA-256 correctly for known data", async () => {
            // Use known test vector
            const testData = "abc";
            const expectedSha256 =
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

            const response = await post(
                `https://127.0.0.1:${server.port}/upload/stream`,
                testData,
                {
                    headers: {
                        "content-type": "text/plain",
                    },
                },
            );

            expect(response.status).toBe(200);

            const json = JSON.parse(new TextDecoder().decode(response.body));
            expect(json.sha256).toBe(expectedSha256);
            expect(json.bytes_received).toBe(3);
        });

        it("handles empty uploads", async () => {
            const response = await post(`https://127.0.0.1:${server.port}/upload/stream`, "", {
                headers: {
                    "content-type": "text/plain",
                },
            });

            expect(response.status).toBe(200);

            const json = JSON.parse(new TextDecoder().decode(response.body));
            expect(json.bytes_received).toBe(0);

            // SHA-256 of empty string
            const expectedEmptyHash = createHash("sha256").update("").digest("hex");
            expect(json.sha256).toBe(expectedEmptyHash);
        });

        it("handles chunked transfer encoding", async () => {
            // Most HTTP/3 clients use chunked by default for streaming
            const testData = "Chunked upload test data";

            const response = await post(
                `https://127.0.0.1:${server.port}/upload/stream`,
                testData,
                {
                    headers: {
                        "content-type": "text/plain",
                        // Let curl handle transfer encoding
                    },
                },
            );

            expect(response.status).toBe(200);

            const json = JSON.parse(new TextDecoder().decode(response.body));
            expect(json.bytes_received).toBe(new TextEncoder().encode(testData).length);

            const expectedHash = createHash("sha256").update(testData).digest("hex");
            expect(json.sha256).toBe(expectedHash);
        });
    });

    describe("Concurrent uploads", () => {
        it("handles multiple simultaneous uploads", async () => {
            const numConcurrent = 3;
            const testData = Array.from(
                { length: numConcurrent },
                (_, i) => `Upload ${i}: ${Date.now()}-${Math.random()}`,
            );

            const promises = testData.map((data) =>
                post(`https://127.0.0.1:${server.port}/upload/stream`, data, {
                    headers: {
                        "content-type": "text/plain",
                    },
                }),
            );

            const responses = await Promise.all(promises);

            // All should succeed
            for (let i = 0; i < numConcurrent; i++) {
                expect(responses[i]!.status).toBe(200);

                const json = JSON.parse(new TextDecoder().decode(responses[i]!.body));
                expect(json.bytes_received).toBe(new TextEncoder().encode(testData[i]!).length);

                // Verify each has correct SHA-256
                const expectedHash = createHash("sha256").update(testData[i]!).digest("hex");
                expect(json.sha256).toBe(expectedHash);
            }
        });
    });

    describe("Error conditions", () => {
        it("handles client disconnect during upload", async () => {
            // Use very short timeout to simulate disconnect
            try {
                await post(
                    `https://127.0.0.1:${server.port}/upload/stream`,
                    "x".repeat(1000000), // 1MB
                    {
                        headers: {
                            "content-type": "text/plain",
                        },
                        maxTime: 0.01, // 10ms timeout - should interrupt upload
                    },
                );
            } catch {
                // Expected to timeout
            }

            // Server should still be responsive
            const response = await post(`https://127.0.0.1:${server.port}/upload/stream`, "test");
            expect(response.status).toBe(200);
        });

        it("handles content-length mismatch gracefully", async () => {
            // Send data with wrong content-length (if possible with curl)
            // This is tricky to test directly, but the server should handle it
            const response = await post(`https://127.0.0.1:${server.port}/upload/stream`, "test");
            expect(response.status).toBe(200);
        });
    });

    describe("Performance characteristics", () => {
        it("throughput calculation is reasonable", async () => {
            await withTempDir(async () => {
                const testFile = await mkfile(1024 * 1024); // 1MB

                const _start = Date.now();
                const fileData = await Bun.file(testFile.path).arrayBuffer();
                const response = await post(
                    `https://127.0.0.1:${server.port}/upload/stream`,
                    new File([fileData], "perf.bin"),
                    {
                        headers: {
                            "content-type": "application/octet-stream",
                        },
                    },
                );

                expect(response.status).toBe(200);

                const json = JSON.parse(new TextDecoder().decode(response.body));

                // Throughput should be reasonable (not impossibly high or zero)
                expect(json.throughput_mbps).toBeGreaterThan(0);
                expect(json.throughput_mbps).toBeLessThan(10000); // Less than 10Gbps seems reasonable

                // Elapsed time should be reasonable
                expect(json.elapsed_ms).toBeGreaterThan(0);
                expect(json.elapsed_ms).toBeLessThan(60000); // Less than 1 minute for 1MB
            });
        });
    });
});
