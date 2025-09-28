import { spawn } from "child_process";
import path from "path";
import { promisify } from "util";
import { getProjectRoot } from "./testUtils";

const execAsync = promisify(require("child_process").exec);
const projectRoot = getProjectRoot();
const wtClientPath = path.join(projectRoot, "zig-out", "bin", "wt-client");

let wtClientBuilt = false;

export async function ensureWtClientBuilt(): Promise<void> {
    if (wtClientBuilt) return;
    await execAsync(`cd ${projectRoot} && zig build wt-client`);
    wtClientBuilt = true;
}

export type WtClientResult = {
    stdout: string;
    stderr: string;
    exitCode: number;
};

export function runWtClient(args: string[], timeoutMs = 5_000, quiet?: boolean): Promise<WtClientResult> {
    const verbose = process.env.H3_VERBOSE === "1" || process.env.H3_VERBOSE === "true";
    return new Promise((resolve, reject) => {
        const proc = spawn(wtClientPath, args, {
            env: process.env,
            cwd: projectRoot,
        });

        let stdout = "";
        let stderr = "";

        proc.stdout?.on("data", (data) => {
            const text = data.toString();
            if (!quiet) stdout += text;
            if (verbose) {
                process.stdout.write(`[wt-client stdout] ${text}`);
            }
        });

        proc.stderr?.on("data", (data) => {
            stderr += data.toString();
            if (verbose) {
                process.stdout.write(`[wt-client stderr] ${data}`);
            }
        });

        const timer = setTimeout(() => {
            proc.kill();
            reject(
                new Error(
                    `wt-client timed out after ${timeoutMs}ms` +
                        (stdout || stderr
                            ? `\nstdout:\n${stdout}\nstderr:\n${stderr}`
                            : ""),
                ),
            );
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
