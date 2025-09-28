import { beforeAll, describe, expect, test } from "bun:test";
import { describeStatic } from "@helpers/dualBinaryTest";
import type { ServerBinaryType } from "@helpers/testUtils";
import { withServer } from "../helpers/spawnServer";
import { getProjectRoot } from "../helpers/testUtils";
import path from "path";
import { spawn } from "child_process";
import { promisify } from "util";

const execAsync = promisify(require("child_process").exec);
const projectRoot = getProjectRoot();
const wtClientPath = path.join(projectRoot, "zig-out", "bin", "wt-client");

let wtClientBuilt = false;
async function ensureWtClientBuilt(): Promise<void> {
    if (wtClientBuilt) return;
    await execAsync(`cd ${projectRoot} && zig build wt-client`);
    wtClientBuilt = true;
}

type WtClientResult = {
    stdout: string;
    stderr: string;
    exitCode: number;
};

function runWtClient(args: string[], timeoutMs = 15_000): Promise<WtClientResult> {
    return new Promise((resolve, reject) => {
        const proc = spawn(wtClientPath, args, {
            env: process.env,
            cwd: projectRoot,
        });

        let stdout = "";
        let stderr = "";

        proc.stdout?.on("data", (data) => {
            stdout += data.toString();
        });

        proc.stderr?.on("data", (data) => {
            stderr += data.toString();
        });

        const timer = setTimeout(() => {
            proc.kill();
            reject(new Error(`wt-client timed out after ${timeoutMs}ms`));
        }, timeoutMs);

        proc.on("exit", (code) => {
            clearTimeout(timer);
            resolve({ stdout, stderr, exitCode: code ?? -1 });
        });

        proc.on("error", (err) => {
            clearTimeout(timer);
            reject(err);
        });
    });
}

describeStatic("WebTransport session lifecycle", (binaryType: ServerBinaryType) => {
    beforeAll(async () => {
        await ensureWtClientBuilt();
    });

    test(
        "server-initiated close is surfaced",
        async () => {
            await withServer(
                async ({ port }) => {
                    const url = `https://127.0.0.1:${port}/wt/close`;
                    const result = await runWtClient([
                        "--quiet",
                        "--url",
                        url,
                        "--expect-close",
                    ]);

                    expect(result.exitCode).toBe(0);
                    expect(result.stderr).toContain("session closed by peer");
                },
                {
                    env: {
                        H3_WEBTRANSPORT: "1",
                        H3_WT_STREAMS: "1",
                        H3_WT_BIDI: "1",
                    },
                    binaryType,
                },
            );
        },
        20_000,
    );

    test(
        "server rejection propagates handshake failure",
        async () => {
            await withServer(
                async ({ port }) => {
                    const url = `https://127.0.0.1:${port}/wt/reject`;
                    const result = await runWtClient(["--quiet", "--url", url]);

                    expect(result.exitCode).not.toBe(0);
                    expect(result.stderr).toMatch(/(WebTransport (?:connect|handshake) failed|ResponseIncomplete)/);
                },
                {
                    env: {
                        H3_WEBTRANSPORT: "1",
                        H3_WT_STREAMS: "1",
                        H3_WT_BIDI: "1",
                    },
                    binaryType,
                },
            );
        },
        15_000,
    );

    test(
        "client-initiated close sends capsule",
        async () => {
            await withServer(
                async ({ port }) => {
                    const url = `https://127.0.0.1:${port}/wt/echo`;
                    const result = await runWtClient([
                        "--url",
                        url,
                        "--close-session",
                    ], 5_000);

                    expect(result.exitCode).toBe(0);
                    expect(result.stderr).toContain("sending CLOSE_SESSION capsule");
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
        },
        5_000,
    );
});
