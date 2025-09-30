import { spawn } from "bun";
import { join } from "path";
import { verboseLog } from "@helpers/logCapture";
import { getProjectRoot, waitForProcessExit } from "@helpers/testUtils";

const DEFAULT_TIMEOUT_MS = Number.parseInt(process.env.H3_E2E_PREBUILD_TIMEOUT ?? "180000", 10);
const AUTO_PREBUILD = process.env.H3_E2E_AUTO_PREBUILD === "1";

let prebuildPromise: Promise<void> | null = null;

async function runBuild(label: string, args: string[], timeoutMs = DEFAULT_TIMEOUT_MS): Promise<void> {
    const projectRoot = getProjectRoot();
    verboseLog(`[E2E] prebuild:${label} start ${new Date().toISOString()} -> ${args.join(" ")}`);

    const proc = spawn({
        cmd: args,
        stdout: process.env.H3_VERBOSE ? "inherit" : "pipe",
        stderr: process.env.H3_VERBOSE ? "inherit" : "pipe",
        cwd: projectRoot,
        env: { ...process.env },
    });

    const stdoutPromise = proc.stdout && !process.env.H3_VERBOSE
        ? new Response(proc.stdout).text()
        : Promise.resolve("");
    const stderrPromise = proc.stderr && !process.env.H3_VERBOSE
        ? new Response(proc.stderr).text()
        : Promise.resolve("");

    await waitForProcessExit(proc, timeoutMs);
    const exitCode = await proc.exited;
    const [stdout, stderr] = await Promise.all([stdoutPromise, stderrPromise]);

    if (exitCode !== 0) {
        const details = [
            `${label} failed with exit code ${exitCode}`,
            stdout ? `stdout:\n${stdout}` : null,
            stderr ? `stderr:\n${stderr}` : null,
        ]
            .filter(Boolean)
            .join("\n\n");
        throw new Error(details);
    }

    verboseLog(`[E2E] prebuild:${label} completed ${new Date().toISOString()}`);
}

function computeCommonArgs(step?: string): string[] {
    const optimize = process.env.H3_OPTIMIZE ?? "ReleaseFast";
    const libevInclude =
        process.env.H3_LIBEV_INCLUDE ??
        (process.platform === "darwin" ? "/opt/homebrew/opt/libev/include" : undefined);
    const libevLib =
        process.env.H3_LIBEV_LIB ??
        (process.platform === "darwin" ? "/opt/homebrew/opt/libev/lib" : undefined);

    const args: string[] = ["zig", "build"];
    if (step) args.push(step);
    args.push("-Dwith-libev=true");
    args.push(`-Doptimize=${optimize}`);
    if (libevInclude) args.push(`-Dlibev-include=${libevInclude}`);
    if (libevLib) args.push(`-Dlibev-lib=${libevLib}`);
    return args;
}

async function verifyArtifacts(): Promise<void> {
    const projectRoot = getProjectRoot();
    const binDir = join(projectRoot, "zig-out", "bin");
    const libDir = join(projectRoot, "zig-out", process.platform === "win32" ? "bin" : "lib");
    const expectedBinaries = ["quic-server", "h3-client", "wt-client"];

    for (const binary of expectedBinaries) {
        const binaryPath = join(binDir, binary);
        const exists = await Bun.file(binaryPath).exists();
        if (!exists) {
            throw new Error(
                `Expected binary missing: ${binaryPath}. Run "zig build -Dwith-libev=true" before executing tests.`,
            );
        }
    }

    const libExt = process.platform === "darwin" ? ".dylib" : process.platform === "win32" ? ".dll" : ".so";
    const libPath = join(libDir, `libzigquicheh3${libExt}`);
    const headerPath = join(projectRoot, "zig-out", "include", "zig_h3.h");

    const libExists = await Bun.file(libPath).exists();
    if (!libExists) {
        throw new Error(
            `Expected Bun FFI library missing: ${libPath}. Run "zig build bun-ffi -Dwith-libev=true" before executing tests.`,
        );
    }

    const headerExists = await Bun.file(headerPath).exists();
    if (!headerExists) {
        throw new Error(
            `Expected Bun FFI header missing: ${headerPath}. Run "zig build bun-ffi -Dwith-libev=true" before executing tests.`,
        );
    }
}

export async function prebuildAllArtifacts(): Promise<void> {
    if (prebuildPromise) {
        return prebuildPromise;
    }

    prebuildPromise = (async () => {
        if (process.env.H3_E2E_SKIP_PREBUILD === "1") {
            verboseLog("[E2E] prebuild skipped via H3_E2E_SKIP_PREBUILD=1");
            return;
        }

        if (AUTO_PREBUILD) {
            await runBuild("bun-ffi", computeCommonArgs("bun-ffi"));
            await runBuild("wt-client", computeCommonArgs("wt-client"));
            await runBuild("install", computeCommonArgs());
        } else {
            verboseLog("[E2E] AUTO_PREBUILD disabled; verifying artifacts only");
        }
        await verifyArtifacts();
    })();

    return prebuildPromise;
}
