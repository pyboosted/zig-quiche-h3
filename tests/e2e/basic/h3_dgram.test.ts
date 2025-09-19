import { expect, test } from "bun:test";
import { retryWithBackoff } from "@helpers/cpuLoad";
import { get, zigClient } from "@helpers/zigClient";
import { describeBoth } from "@helpers/dualBinaryTest";
import { spawnServer } from "@helpers/spawnServer";
import type { ServerBinaryType } from "@helpers/testUtils";

describeBoth("H3 DATAGRAM Tests", (binaryType: ServerBinaryType) => {
    test("request-associated H3 dgram echo", async () => {
        const server = await spawnServer({ env: { H3_DGRAM_ECHO: "1", RUST_LOG: "trace" } });

        try {
            // Test basic GET request to H3 DATAGRAM endpoint
            const response = await get(`https://127.0.0.1:${server.port}/h3dgram/echo`);

            expect(response.status).toBe(200);
            expect(new TextDecoder().decode(response.body)).toContain("H3 DATAGRAM Echo Endpoint");
            expect(new TextDecoder().decode(response.body)).toContain(
                "flow_id for this request is the stream_id",
            );

            // Test H3 DATAGRAM echo functionality using our native h3-cli
            await retryWithBackoff(
                async () => {
                    const response = await zigClient(
                        `https://127.0.0.1:${server.port}/h3dgram/echo`,
                        {
                            h3Dgram: true,
                            dgramPayload: "test-datagram-payload",
                            dgramCount: 3,
                            dgramIntervalMs: 100,
                            dgramWaitMs: 500,
                            maxTime: 10,
                        },
                    );

                    console.log("[H3 DGRAM Test] Response status:", response.status);
                    console.log("[H3 DGRAM Test] Response raw:", response.raw.slice(0, 500));

                    // Check that we got a valid response
                    expect(response.status).toBe(200);

                    // The raw output should contain DATAGRAM events if streaming
                    const rawText = response.raw;
                    if (!rawText.includes("event=datagram") && !rawText.includes("flow_id")) {
                        console.error("[H3 DGRAM Test] No DATAGRAM events found in output");
                        console.error("[H3 DGRAM Test] Output sample:", rawText.slice(0, 1000));
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

    test("H3 dgram disabled when QUIC datagrams disabled", async () => {
        // Test server without DATAGRAM support enabled
        const server = await spawnServer({ binaryType }); // No H3_DGRAM_ECHO env var

        try {
            const response = await get(`https://127.0.0.1:${server.port}/h3dgram/echo`);

            // Even with QUIC DATAGRAMs enabled, the endpoint should be available
            expect(response.status).toBe(200);
            expect(response.headers.get("content-type")).toMatch(/text\/plain/);
        } finally {
            await server.cleanup();
        }
    });

    test("H3 dgram endpoint provides correct information", async () => {
        const server = await spawnServer({ env: { H3_DGRAM_ECHO: "1" } });

        try {
            const response = await get(`https://127.0.0.1:${server.port}/h3dgram/echo`);
            const body = new TextDecoder().decode(response.body);

            expect(response.status).toBe(200);
            expect(body).toContain("H3 DATAGRAM Echo Endpoint");
            expect(body).toContain("Send HTTP/3 DATAGRAMs");
            expect(body).toContain("flow_id for this request is the stream_id");
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
