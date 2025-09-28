import { describe, expect, test } from "bun:test";
import { describeStatic } from "@helpers/dualBinaryTest";
import type { ServerBinaryType } from "@helpers/testUtils";
import { withServer } from "../helpers/spawnServer";
import { ensureWtClientBuilt, runWtClient } from "@helpers/wtClient";

const SESSION_URL = "/wt/echo";

function extractCloseInfo(stderr: string) {
    const match = stderr.match(/sending CLOSE_SESSION capsule/);
    return match !== null;
}

describeStatic("WebTransport capsules", (binaryType: ServerBinaryType) => {
    test(
        "client close capsule is emitted",
        async () => {
            await ensureWtClientBuilt();
            const { result } = await withServer(
                async ({ port }) => {
                    const run = await runWtClient(
                        [
                            "--url",
                            `https://127.0.0.1:${port}${SESSION_URL}`,
                            "--close-session",
                        ],
                        5_000,
                        true,
                    );
                    return { result: run };
                },
                {
                    env: {
                        H3_WEBTRANSPORT: "1",
                        H3_WT_STREAMS: "1",
                        H3_WT_BIDI: "1",
                    },
                    binaryType,
                    timeoutMs: 5_000,
                },
            );

            expect(result.exitCode).toBe(0);
            expect(extractCloseInfo(result.stderr)).toBeTrue();
        },
        5_000,
    );
});
