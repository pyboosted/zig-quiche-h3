import { describe, it } from "bun:test";
import { spawn } from "bun";
import { join } from "path";
import { getProjectRoot, waitForProcessExit } from "@helpers/testUtils";

const projectRoot = getProjectRoot();

async function runWorker(timeoutMs = 60_000) {
    const workerPath = join(
        projectRoot,
        "tests",
        "e2e",
        "webtransport",
        "ffi_client_webtransport.worker.test.ts",
    );

    const proc = spawn({
        cmd: ["bun", "test", workerPath],
        stdout: "pipe",
        stderr: "pipe",
        env: {
            ...process.env,
            BUN_WORKERS: process.env.BUN_WORKERS ?? "1",
            H3_E2E_RUN_WORKER: "1",
        },
    });

    const stdoutPromise = proc.stdout ? new Response(proc.stdout).text() : Promise.resolve("");
    const stderrPromise = proc.stderr ? new Response(proc.stderr).text() : Promise.resolve("");

    await waitForProcessExit(proc, timeoutMs);
    const exitCode = await proc.exited;
    const [stdout, stderr] = await Promise.all([stdoutPromise, stderrPromise]);

    if (exitCode !== 0) {
        const message = [
            `bun test ${workerPath} exited with code ${exitCode}`,
            stdout ? `stdout:\n${stdout}` : null,
            stderr ? `stderr:\n${stderr}` : null,
        ]
            .filter(Boolean)
            .join("\n\n");
        throw new Error(message);
    }
}

describe("FFI WebTransport client (subprocess)", () => {
    it("runs the worker suite via separate bun process", async () => {
        await runWorker();
    }, 60_000);
});
