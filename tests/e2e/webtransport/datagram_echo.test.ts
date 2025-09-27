import { beforeAll, describe, expect, test } from "bun:test";
import { describeBoth } from "@helpers/dualBinaryTest";
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

describeBoth("WebTransport datagram echo", (binaryType: ServerBinaryType) => {
    beforeAll(async () => {
        await ensureWtClientBuilt();
    });

    test(
        "echoes multiple datagrams",
        async () => {
            await withServer(
                async ({ port }) => {
                    const url = `https://127.0.0.1:${port}/wt/echo`;
                    const result = await runWtClient(["--url", url, "--count", "5"]);

                    expect(result.exitCode).toBe(0);
                    const matches = result.stderr.match(
                        /Received echo: WebTransport datagram #\d+ \(len=\d+\)/g,
                    );
                    expect(matches).toBeTruthy();
                    expect(matches!.length).toBeGreaterThanOrEqual(5);
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
        "handles large datagram payloads",
        async () => {
            await withServer(
                async ({ port }) => {
                    const url = `https://127.0.0.1:${port}/wt/echo`;
                    const payloadLen = 1200;
                    const result = await runWtClient([
                        "--url",
                        url,
                        "--payload-size",
                        payloadLen.toString(),
                    ]);

                    expect(result.exitCode).toBe(0);
                    expect(result.stderr).toContain(`len=${payloadLen}`);
                    const matches = result.stderr.match(
                        /Received echo: WebTransport datagram #\d+ \(len=\d+\)/g,
                    );
                    expect(matches).toBeTruthy();
                    expect(matches![0]).toContain(`len=${payloadLen}`);
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
});
