import "../test-runner";
import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { describeBoth } from "@helpers/dualBinaryTest";
import { spawnServer, type ServerInstance } from "@helpers/spawnServer";
import { zigClient } from "@helpers/zigClient";
import { mkfile, type ServerBinaryType } from "@helpers/testUtils";

describeBoth("Per-connection download cap", (binaryType: ServerBinaryType) => {
    let server: ServerInstance;

    beforeAll(async () => {
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

    it("rejects second concurrent file download with 503 when cap=1", async () => {
        const tf = await mkfile(3 * 1024 * 1024);
        const relativePath = tf.path.split("/tests/").pop() || tf.path;
        const url = `https://127.0.0.1:${server.port}/download/${relativePath}`;

        const response = await zigClient(url, {
            concurrent: 2,
            curlCompat: true,
        });

        const responses = response.responses ?? [response];
        expect(responses.length).toBe(2);

        const statuses = responses.map((r) => r.status);
        const ok = statuses.filter((s) => s === 200).length;
        const svc = statuses.filter((s) => s === 503).length;
        expect(ok).toBe(1);
        expect(svc).toBe(1);
    });

    it("does not count memory streaming as downloads", async () => {
        const url = `https://127.0.0.1:${server.port}/stream/test`;
        const response = await zigClient(url, {
            concurrent: 2,
            curlCompat: true,
        });
        const responses = response.responses ?? [response];
        expect(responses.length).toBe(2);
        expect(responses.every((res) => res.status === 200)).toBeTrue();
    });
});
