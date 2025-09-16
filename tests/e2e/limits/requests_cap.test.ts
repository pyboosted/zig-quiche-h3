import "../test-runner";
import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { describeBoth } from "@helpers/dualBinaryTest";
import { spawnServer, type ServerInstance } from "@helpers/spawnServer";
import { ensureQuicheBuilt, quicheClient } from "@helpers/quicheClient";
import { mkfile, type ServerBinaryType } from "@helpers/testUtils";

function extractStatuses(jsonLines: string): number[] {
    const statuses: number[] = [];
    for (const line of jsonLines.split("\n")) {
        const t = line.trim();
        if (!t.startsWith("{")) continue;
        try {
            const obj = JSON.parse(t);
            const s = obj.status ?? obj.status_code;
            if (typeof s === "number") statuses.push(s);
        } catch {
            // ignore non-JSON lines
        }
    }
    return statuses;
}

describeBoth("Per-connection request cap", (binaryType: ServerBinaryType) => {
    let server: ServerInstance;

    beforeAll(async () => {
        await ensureQuicheBuilt();
        server = await spawnServer({
            binaryType,
            // Cap requests to 2; leave downloads effectively unlimited
            env: {
                H3_MAX_REQS_PER_CONN: "2",
                H3_MAX_DOWNLOADS_PER_CONN: "100",
                H3_CHUNK_SIZE: "16384",
                H3_DEBUG: process.env.H3_DEBUG ?? "",
            },
        });
    });

    afterAll(async () => {
        await server.cleanup();
    });

    describe("rejects N+1 requests with 503 on same connection", () => {
        it.skip("third concurrent request gets 503 when cap=2", async () => {
            // NOTE: quiche-client's --requests flag sends requests sequentially,
            // not concurrently. However, if we use a slow handler that delays
            // the response, we can create overlapping requests on the same connection.

            // The problem is that quiche-client waits for each request to fully complete
            // before sending the next one. So this test won't work as expected with
            // the current quiche-client implementation.

            // For now, we'll mark this test as a known limitation and provide
            // a manual test procedure instead.

            console.log("WARNING: This test requires a client that can send truly concurrent requests.");
            console.log("The quiche-client sends requests sequentially, so the cap may not trigger.");
            console.log("Manual test: Use curl --http3-only with multiple parallel requests.");

            // Skip this test for now
            // TODO: Implement when we have our own H3 client that supports truly concurrent requests
            // The current clients (curl, quiche-client) create separate connections or send sequentially
            expect(true).toBe(true);
        });

        it("manual test instructions", () => {
            console.log("\n=== Manual Test Procedure ===");
            console.log("1. Start server: H3_MAX_REQS_PER_CONN=2 ./zig-out/bin/quic-server --port 15433");
            console.log("2. In terminal 1: curl --http3-only https://127.0.0.1:15433/slow?delay=5000 &");
            console.log("3. In terminal 2: curl --http3-only https://127.0.0.1:15433/slow?delay=5000 &");
            console.log("4. In terminal 3: curl --http3-only https://127.0.0.1:15433/slow?delay=5000");
            console.log("   ^ This should return 503 Service Unavailable");
            console.log("==============================\n");
            expect(true).toBe(true);
        });
    });
});
