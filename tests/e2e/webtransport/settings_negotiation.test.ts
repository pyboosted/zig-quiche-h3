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

function runWtClient(args: string[], timeoutMs = 3_000): Promise<WtClientResult> {
    return new Promise((resolve, reject) => {
        const proc = spawn(wtClientPath, args, {
            env: process.env,
            cwd: projectRoot,
        });

        let stdout = "";
        let stderr = "";

        let timedOut = false;

        proc.stdout?.on("data", (data) => {
            stdout += data.toString();
        });

        proc.stderr?.on("data", (data) => {
            stderr += data.toString();
        });

        const timer = setTimeout(() => {
            timedOut = true;
            proc.kill();
        }, timeoutMs);

        proc.on("exit", (code) => {
            clearTimeout(timer);
            if (timedOut) {
                resolve({ stdout, stderr, exitCode: -1 });
                return;
            }
            resolve({ stdout, stderr, exitCode: code ?? -1 });
        });

        proc.on("error", (err) => {
            clearTimeout(timer);
            reject(err);
        });
    });
}

describeStatic("WebTransport settings negotiation", (binaryType: ServerBinaryType) => {
    beforeAll(async () => {
        await ensureWtClientBuilt();
    });

    test(
        "fails when H3 DATAGRAM support is disabled",
        async () => {
            await withServer(
                async ({ port, getLogs }) => {
                    const url = `https://127.0.0.1:${port}/wt/echo`;
                    const result = await runWtClient([
                        "--quiet",
                        "--url",
                        url,
                    ], 3_000);

                    expect(result.exitCode).toBe(-1);
                    const logs = getLogs().join("\n");
                    expect(logs).toContain("QUIC server running");
                },
                {
                    env: {
                        H3_WEBTRANSPORT: "1",
                        H3_WT_STREAMS: "1",
                        H3_WT_BIDI: "1",
                        H3_ENABLE_DGRAM: "0",
                    },
                    binaryType,
                },
            );
        },
        5_000,
    );
});
