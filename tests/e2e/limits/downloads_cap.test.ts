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
            // ignore
        }
    }
    return statuses;
}

describeBoth("Per-connection download cap", (binaryType: ServerBinaryType) => {
    let server: ServerInstance;

    beforeAll(async () => {
        await ensureQuicheBuilt();
        server = await spawnServer({
            binaryType,
            env: {
                H3_MAX_DOWNLOADS_PER_CONN: "1",
                H3_MAX_REQS_PER_CONN: "100",
                H3_CHUNK_SIZE: "16384",
                H3_DEBUG: process.env.H3_DEBUG ?? "",
            },
        });
    });

    afterAll(async () => {
        await server.cleanup();
    });

    it.skip("rejects second concurrent file download with 503 when cap=1", async () => {
        // TODO: Implement when we have our own H3 client that supports truly concurrent requests
        // The current quiche-client sends requests sequentially, not concurrently
        // Prepare a small test file (~3MB) so the first download stays active
        const tf = await mkfile(3 * 1024 * 1024);
        const relativePath = tf.path.split("/tests/").pop() || tf.path;
        const url = `https://127.0.0.1:${server.port}/download/${relativePath}`;

        const resp = await quicheClient(url, { requests: 2, dumpJson: true, maxData: 20000000 });

        // quiche-client may exit non-zero when one request returns 503
        const statuses = extractStatuses(resp.output);
        const ok = statuses.filter((s) => s === 200).length;
        const svc = statuses.filter((s) => s === 503).length;
        expect(statuses.length).toBe(2);
        expect(ok).toBe(1);
        expect(svc).toBe(1);
    });

    it.skip("does not count memory streaming as downloads", async () => {
        // TODO: Test with concurrent client - memory streams shouldn't count against download cap
        // With download cap=1, two memory-backed streams should both succeed
        const url = `https://127.0.0.1:${server.port}/stream/test`;
        const resp = await quicheClient(url, { requests: 2, dumpJson: true, maxData: 20000000 });
        const statuses = extractStatuses(resp.output);
        expect(statuses.length).toBe(2);
        expect(statuses.every((s) => s === 200)).toBeTrue();
    });
});
