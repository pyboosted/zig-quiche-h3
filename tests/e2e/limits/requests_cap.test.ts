import "../test-runner";
import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { describeStatic } from "@helpers/dualBinaryTest";
import { type ServerInstance, spawnServer } from "@helpers/spawnServer";
import type { ServerBinaryType } from "@helpers/testUtils";
import { zigClient } from "@helpers/zigClient";
import { verboseLog } from "@helpers/logCapture";

function _extractStatuses(jsonLines: string): number[] {
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

describeStatic("Per-connection request cap", (binaryType: ServerBinaryType) => {
    let server: ServerInstance;

    beforeAll(async () => {
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
        it("third concurrent request gets 503 when cap=2", async () => {
            const url = `https://127.0.0.1:${server.port}/slow?delay=1500`;

            const response = await zigClient(url, {
                concurrent: 3,
                curlCompat: true,
            });

            const responses = response.responses ?? [response];
            expect(responses.length).toBe(3);

            const statusCounts = responses.reduce(
                (acc, res) => {
                    const key = res.status;
                    acc[key] = (acc[key] ?? 0) + 1;
                    return acc;
                },
                {} as Record<number, number>,
            );

            expect(statusCounts[200] ?? 0).toBe(2);
            expect(statusCounts[503] ?? 0).toBe(1);
        });

        it("manual test instructions", () => {
            verboseLog("\n=== Manual Test Procedure ===");
            verboseLog(
                "1. Start server: H3_MAX_REQS_PER_CONN=2 ./zig-out/bin/quic-server --port 15433",
            );
            verboseLog(
                "2. In terminal 1: curl --http3-only https://127.0.0.1:15433/slow?delay=5000 &",
            );
            verboseLog(
                "3. In terminal 2: curl --http3-only https://127.0.0.1:15433/slow?delay=5000 &",
            );
            verboseLog(
                "4. In terminal 3: curl --http3-only https://127.0.0.1:15433/slow?delay=5000",
            );
            verboseLog("   ^ This should return 503 Service Unavailable");
            verboseLog("==============================\n");
            expect(true).toBe(true);
        });
    });
});
