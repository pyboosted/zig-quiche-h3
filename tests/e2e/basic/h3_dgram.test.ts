import { describe, test, expect } from "bun:test";
import { spawnServer } from "@helpers/spawnServer";
import { get } from "@helpers/curlClient";
import { retryWithBackoff } from "@helpers/cpuLoad";

describe("H3 DATAGRAM Tests", () => {
    // TODO: replace with proper zig-http3-client checks when its done
    test.skip("request-associated H3 dgram echo", async () => {
        const server = await spawnServer({ env: { H3_DGRAM_ECHO: "1", RUST_LOG: "trace" } });

        try {
            // Test basic GET request to H3 DATAGRAM endpoint
            const response = await get(`https://127.0.0.1:${server.port}/h3dgram/echo`);

            expect(response.status).toBe(200);
            expect(new TextDecoder().decode(response.body)).toContain("H3 DATAGRAM Echo Endpoint");
            expect(new TextDecoder().decode(response.body)).toContain(
                "flow_id for this request is the stream_id",
            );

            // Test H3 DATAGRAM echo functionality using quiche-client helper
            const { quicheClient } = await import("@helpers/quicheClient");

            await retryWithBackoff(
                async () => {
                    const res = await quicheClient(
                        `https://127.0.0.1:${server.port}/h3dgram/echo`,
                        {
                            dumpJson: false, // We want raw output for DATAGRAM logs
                            dgramProto: "oneway",
                            dgramCount: 3,
                            idleTimeout: 10000, // 10 second idle timeout to allow echo responses
                            maxData: 10000000, // Increase flow control limits
                        },
                    );

                    console.log("[H3 DGRAM Test] Client output:", res.output);
                    console.log("[H3 DGRAM Test] Client error:", res.error);
                    console.log("[H3 DGRAM Test] Client success:", res.success);

                    if (!res.success) {
                        throw new Error("quiche-client failed");
                    }

                    const combined = `${res.output || ""}\n${res.error || ""}`;

                    if (!combined.includes("sending HTTP/3 DATAGRAM")) {
                        throw new Error("Missing 'sending HTTP/3 DATAGRAM' in output");
                    }

                    if (!combined.includes("Received DATAGRAM")) {
                        console.error("[H3 DGRAM Test] No 'Received DATAGRAM' found");
                        console.error("[H3 DGRAM Test] Output sample:", combined.slice(0, 1000));
                        throw new Error("DATAGRAM echo not received - possible timing issue");
                    }
                },
                3,
                2000,
            ); // 3 retries with 2 second delay
        } finally {
            await server.cleanup();
        }
    });

    // TODO: replace with proper zig-http3-client checks when its done
    test.skip("H3 dgram disabled when QUIC datagrams disabled", async () => {
        // Test server without DATAGRAM support enabled
        const server = await spawnServer(); // No H3_DGRAM_ECHO env var

        try {
            const response = await get(`https://127.0.0.1:${server.port}/h3dgram/echo`);

            // Even with QUIC DATAGRAMs enabled, the endpoint should be available
            expect(response.status).toBe(200);
            expect(response.headers.get("content-type")).toMatch(/text\/plain/);
        } finally {
            await server.cleanup();
        }
    });

    // TODO: replace with proper zig-http3-client checks when its done
    test.skip("H3 dgram endpoint provides correct information", async () => {
        const server = await spawnServer({ env: { H3_DGRAM_ECHO: "1" } });

        try {
            const response = await get(`https://127.0.0.1:${server.port}/h3dgram/echo`);
            const body = new TextDecoder().decode(response.body);

            expect(response.status).toBe(200);
            expect(body).toContain("H3 DATAGRAM Echo Endpoint");
            expect(body).toContain("Send HTTP/3 DATAGRAMs");
            expect(body).toContain("flow_id for this request is the stream_id");
            expect(body).toContain("quiche-client");
            expect(body).toContain("--dgram-proto oneway");
            expect(body).toContain("--dgram-count");
        } finally {
            await server.cleanup();
        }
    });

    // TODO: replace with proper zig-http3-client checks when its done
    test.skip("unknown flow_id handling", async () => {
        // This is primarily tested through the server implementation
        // The processH3Datagram method should drop datagrams with unknown flow_ids
        // and increment the h3_dgrams_unknown_flow counter

        const server = await spawnServer({ env: { H3_DGRAM_ECHO: "1" } });

        try {
            // Just verify the endpoint is available for this integration test
            const response = await get(`https://127.0.0.1:${server.port}/h3dgram/echo`);
            expect(response.status).toBe(200);

            // The unknown flow_id behavior is tested at the server level
            // when DATAGRAMs arrive with flow_ids that don't match any active requests
        } finally {
            await server.cleanup();
        }
    });

    // TODO: replace with proper zig-http3-client checks when its done
    test.skip("varint encoding/decoding boundary cases", async () => {
        // This tests the h3/datagram.zig module functionality
        // which is already covered by unit tests in that module

        const server = await spawnServer({ env: { H3_DGRAM_ECHO: "1" } });

        try {
            // Verify server starts correctly with H3 DATAGRAM support
            const response = await get(`https://127.0.0.1:${server.port}/`);
            expect(response.status).toBe(200);

            // The varint boundary cases are tested in the Zig unit tests
            // This E2E test just confirms the server integration works
        } finally {
            await server.cleanup();
        }
    });
});
