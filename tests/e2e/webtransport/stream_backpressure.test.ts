import { beforeAll, describe, expect, test } from "bun:test";
import { describeBoth } from "@helpers/dualBinaryTest";
import type { ServerBinaryType } from "@helpers/testUtils";
import { withServer } from "../helpers/spawnServer";
import { ensureWtClientBuilt, runWtClient } from "@helpers/wtClient";

const STREAM_BYTES = 64 * 1024; // 64 KiB
const STREAM_CHUNK = 16 * 1024;
const STREAM_DELAY_MS = 0;

describeBoth("WebTransport stream backpressure", (binaryType: ServerBinaryType) => {
    beforeAll(async () => {
        await ensureWtClientBuilt();
    });

    test(
        "server logs send backpressure and client completes echo",
        async () => {
            await withServer(
                async ({ port, getLogs, cleanup }) => {
                    const url = `https://127.0.0.1:${port}/wt/echo`;
                    const result = await runWtClient(
                        [
                            "--url",
                            url,
                            "--stream-bytes",
                            STREAM_BYTES.toString(),
                            "--stream-chunk",
                            STREAM_CHUNK.toString(),
                            "--stream-delay",
                            STREAM_DELAY_MS.toString(),
                        ],
                        5_000,
                    ).catch(async (err) => {
                        await cleanup();
                        const logs = getLogs().join("\n");
                        console.error("[test] server logs during failure:\n" + logs);
                        throw err;
                    });

                    expect(result.exitCode).toBe(0);
                    expect(result.stderr).toContain("stream echo verified bytes=" + STREAM_BYTES);
                    expect(result.stderr).toContain("blocked=true");

                    const logs = getLogs().join("\n");
                    expect(logs).toContain("WT stream send would block");
                },
                {
                    env: {
                        H3_WEBTRANSPORT: "1",
                        H3_WT_STREAMS: "1",
                        H3_WT_BIDI: "1",
                        H3_WT_STREAM_PENDING_MAX: "8192",
                        H3_LOG_LEVEL: "debug",
                        H3_QLOG: "0",
                    },
                    binaryType,
                    timeoutMs: 5_000,
                },
            );
        },
        5_000,
    );
});
