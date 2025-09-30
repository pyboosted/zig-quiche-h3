import { type Subprocess, spawn } from "bun";
import {
    checkDependencies,
    getCertPath,
    getProjectRoot,
    getServerBinary,
    randPort,
    ServerBinaryType,
    waitFor,
    waitForProcessExit,
} from "./testUtils";
import { get } from "./zigClient";
import { isVerboseMode, verboseLog } from "./logCapture";
import { captureServerLogs } from "./failureCapture";
import { prebuildAllArtifacts } from "./prebuild";

type LockHandle = { release(): void };

const MAX_CONCURRENT_SERVERS_RAW = process.env.H3_E2E_MAX_SERVERS;
const MAX_CONCURRENT_SERVERS = (() => {
    if (MAX_CONCURRENT_SERVERS_RAW === undefined) {
        return Number.POSITIVE_INFINITY;
    }
    const parsed = Number.parseInt(MAX_CONCURRENT_SERVERS_RAW, 10);
    if (!Number.isFinite(parsed) || parsed <= 0) {
        return Number.POSITIVE_INFINITY;
    }
    return parsed;
})();

function createServerLock(limit: number) {
    const globalAny = globalThis as unknown as {
        __e2eServerLock?: {
            acquire: () => Promise<LockHandle>;
        };
    };

    if (!globalAny.__e2eServerLock) {
        let available = Math.max(1, limit);
        const waiters: Array<() => void> = [];

        const acquire = async (): Promise<LockHandle> => {
            if (available > 0) {
                available -= 1;
                let released = false;
                const release = () => {
                    if (released) return;
                    released = true;
                    available += 1;
                    if (waiters.length > 0) {
                        const next = waiters.shift()!;
                        next();
                    }
                };
                return { release };
            }

            await new Promise<void>((resolve) => {
                waiters.push(resolve);
            });

            let released = false;
            const release = () => {
                if (released) return;
                released = true;
                available += 1;
                if (waiters.length > 0) {
                    const next = waiters.shift()!;
                    next();
                }
            };
            available -= 1;
            return { release };
        };

        globalAny.__e2eServerLock = { acquire };
    }

    return globalAny.__e2eServerLock!;
}

const serverLock = Number.isFinite(MAX_CONCURRENT_SERVERS)
    ? createServerLock(MAX_CONCURRENT_SERVERS)
    : null;

/**
 * Server instance with cleanup capability
 */
export interface ServerInstance {
    proc: Subprocess;
    port: number;
    cleanup: () => Promise<void>;
    getLogs: () => string[];
}

/**
 * Options for spawning the server
 */
export interface SpawnServerOptions {
    port?: number;
    qlog?: boolean;
    debugLog?: boolean;
    env?: Record<string, string>;
    timeoutMs?: number;
    binaryType?: ServerBinaryType;
    skipConcurrencyGuard?: boolean;
}

/**
 * Spawn the zig-quiche-h3 server and wait for it to be ready
 */
export async function spawnServer(opts: SpawnServerOptions = {}): Promise<ServerInstance> {
    const shouldUseLock = !opts.skipConcurrencyGuard && serverLock !== null;
    const lockHandle = shouldUseLock ? await serverLock!.acquire() : null;
    let released = !shouldUseLock;
    const releaseLock = () => {
        if (released) return;
        released = true;
        lockHandle?.release();
    };

    verboseLog(`[E2E] spawnServer() started at ${new Date().toISOString()}`);
    const port =
        opts.port ?? (process.env.H3_TEST_PORT ? Number(process.env.H3_TEST_PORT) : randPort());
    verboseLog(`[E2E] Selected port: ${port}`);

    // Check dependencies first
    verboseLog(`[E2E] Checking dependencies at ${new Date().toISOString()}`);
    await checkDependencies();
    verboseLog(`[E2E] Dependencies checked at ${new Date().toISOString()}`);

    // Ensure server is built before attempting to spawn
    const binaryType = opts.binaryType || ServerBinaryType.Static;
    verboseLog(`[E2E] Calling ensureServerBuilt(${binaryType}) at ${new Date().toISOString()}`);
    await ensureServerBuilt(binaryType);
    verboseLog(`[E2E] ensureServerBuilt() completed at ${new Date().toISOString()}`);

    // Get paths using the new utilities - works from any directory
    const serverPath = getServerBinary(binaryType);
    const certPath = getCertPath("cert.crt");
    const keyPath = getCertPath("cert.key");

    // Build server arguments
    const args = [
        serverPath,
        "--port",
        port.toString(),
        "--cert",
        certPath,
        "--key",
        keyPath,
        "--files-dir",
        "tests",
    ];

    // QLOG configuration
    if (opts.qlog === false || (opts.qlog === undefined && !process.env.H3_QLOG)) {
        args.push("--no-qlog");
    }

    // Debug logging
    if (opts.debugLog || process.env.H3_DEBUG) {
        // Server already has debug logging enabled by default
    }

    // Environment variables
    const env = {
        ...process.env,
        ...opts.env,
    };

    // Add SSLKEYLOGFILE for debugging if requested
    if (process.env.H3_DEBUG) {
        env.SSLKEYLOGFILE = `./tmp/sslkeylog-${port}.txt`;
    }

    // Log environment variables relevant to server config
    if (opts.env?.H3_MAX_DOWNLOADS_PER_CONN) {
        verboseLog(`[E2E] H3_MAX_DOWNLOADS_PER_CONN=${opts.env.H3_MAX_DOWNLOADS_PER_CONN}`);
    }
    if (opts.env?.H3_MAX_REQS_PER_CONN) {
        verboseLog(`[E2E] H3_MAX_REQS_PER_CONN=${opts.env.H3_MAX_REQS_PER_CONN}`);
    }

    verboseLog(`Spawning server on port ${port}...`);
    verboseLog(`[E2E] Server command: ${args.join(" ")}`);
    verboseLog(`[E2E] Working directory: ${getProjectRoot()}`);

    // Buffer to store server logs
    const serverLogs: string[] = [];

    // Spawn the server process
    verboseLog(`[E2E] Calling spawn() at ${new Date().toISOString()}`);
    const proc = spawn({
        cmd: args,
        stdout: "pipe",
        stderr: "pipe",
        env,
        cwd: getProjectRoot(), // Run server from project root for consistent file resolution
    });
    verboseLog(`[E2E] Process spawned with PID: ${proc.pid} at ${new Date().toISOString()}`);

    // Only capture output if not in verbose mode to avoid complexity
    const captureStream = (
        stream: ReadableStream<Uint8Array> | null | undefined,
        label: "stdout" | "stderr",
    ): void => {
        if (!stream) return;

        const decoder = new TextDecoder();
        let pending = "";

        (async () => {
            const reader = stream.getReader();
            try {
                while (true) {
                    const { value, done } = await reader.read();
                    if (done) break;
                    if (!value || value.byteLength == 0) continue;
                    pending += decoder.decode(value, { stream: true });

                    let newlineIndex = pending.indexOf("\n");
                    while (newlineIndex !== -1) {
                        const line = pending.slice(0, newlineIndex);
                        pending = pending.slice(newlineIndex + 1);
                        const entry = `[${label}] ${line}`;
                        serverLogs.push(entry);
                        if (isVerboseMode()) {
                            const target = label === "stdout" ? process.stdout : process.stderr;
                            target.write(`[server ${label}] ${line}\n`);
                        }
                        newlineIndex = pending.indexOf("\n");
                    }
                }

                const trailing = pending + decoder.decode();
                if (trailing.length > 0) {
                    const entry = `[${label}] ${trailing}`;
                    serverLogs.push(entry);
                    if (isVerboseMode()) {
                        const target = label === "stdout" ? process.stdout : process.stderr;
                        target.write(`[server ${label}] ${trailing}\n`);
                    }
                    pending = "";
                }
            } catch (err) {
                verboseLog(`[E2E] Error capturing server ${label}: ${err}`);
            } finally {
                reader.releaseLock();
            }
        })();
    };

    captureStream(proc.stdout, "stdout");
    captureStream(proc.stderr, "stderr");

    // Create cleanup function
    const cleanup = async (): Promise<void> => {
        verboseLog(`Shutting down server on port ${port}...`);

        try {
            // Add server logs to failure capture before cleanup
            if (serverLogs.length > 0) {
                captureServerLogs(serverLogs);
            }

            // Send SIGTERM for graceful shutdown
            proc.kill("SIGTERM");

            // Wait for graceful shutdown with timeout
            await Promise.race([
                proc.exited,
                Bun.sleep(100), // 100ms timeout - Zig server shuts down quickly
            ]);

            // Force kill if still running
            if (!proc.killed) {
                proc.kill("SIGKILL");
                await waitForProcessExit(proc, 1000);
            }
        } catch (error) {
            verboseLog(`Error during cleanup: ${error}`);
        } finally {
            releaseLock();
        }
    };

    // Wait for server to be ready
    const timeoutMs = opts.timeoutMs ?? 2000; // Reduced from 10s - server starts in <100ms
    const _deadline = Date.now() + timeoutMs;

    try {
        verboseLog(`[E2E] Waiting for server readiness at ${new Date().toISOString()}`);
        await waitFor(
            async () => {
                try {
                    // Use GET / for readiness probe (not HEAD as per audit)
                    verboseLog(
                        `[E2E] Probing https://127.0.0.1:${port}/ at ${new Date().toISOString()}`,
                    );
                    const response = await get(`https://127.0.0.1:${port}/`);
                    const ready = response.status === 200;
                    verboseLog(
                        `[E2E] Probe result: ${ready ? "ready" : "not ready"} (status: ${response.status})`,
                    );
                    return ready;
                } catch (err) {
                    verboseLog(`[E2E] Probe failed: ${err}`);
                    return false;
                }
            },
            timeoutMs,
            50, // Reduced from 150ms - server starts almost instantly
        );

        verboseLog(`Server ready on port ${port}`);

        await Bun.sleep(50);

        return {
            proc,
            port,
            cleanup,
            getLogs: () => serverLogs,
        };
    } catch (error) {
        // Cleanup on startup failure
        await cleanup();

        // Include captured logs in error message
        const errorLogs = serverLogs.length > 0 ? `\n\nServer logs:\n${serverLogs.join("\n")}` : "";

        throw new Error(
            `Server failed to start within ${timeoutMs}ms. Error: ${error}${errorLogs}`,
        );
    }
}

/**
 * Spawn server for a single test with automatic cleanup
 */
export async function withServer<T>(
    testFn: (server: ServerInstance) => Promise<T>,
    options?: SpawnServerOptions,
): Promise<T> {
    const server = await spawnServer(options);
    try {
        return await testFn(server);
    } finally {
        await server.cleanup();
        // server.cleanup() already releases the lock; nothing additional needed here.
    }
}

/**
 * Check if the server binary exists and is executable
 */
export async function checkServerBinary(
    binaryType: ServerBinaryType = ServerBinaryType.Static,
): Promise<boolean> {
    verboseLog(`[E2E] checkServerBinary(${binaryType}) started at ${new Date().toISOString()}`);
    try {
        const serverPath = getServerBinary(binaryType);
        verboseLog(`[E2E] Checking if server binary exists at: ${serverPath}`);

        // Simply check if the file exists - don't try to run it with --help
        // as the server doesn't support --help and will hang
        const exists = await Bun.file(serverPath).exists();
        verboseLog(`[E2E] Server binary (${binaryType}) exists: ${exists}`);
        return exists;
    } catch (err) {
        verboseLog(`[E2E] checkServerBinary() error: ${err}`);
        // Binary doesn't exist or isn't accessible
        return false;
    } finally {
        verboseLog(`[E2E] checkServerBinary() completed at ${new Date().toISOString()}`);
    }
}

/**
 * Build the server if needed
 */
export async function ensureServerBuilt(
    binaryType: ServerBinaryType = ServerBinaryType.Static,
): Promise<void> {
    verboseLog(`[E2E] ensureServerBuilt(${binaryType}) started at ${new Date().toISOString()}`);

    // Prebuild happens during global setup, but guard against missing artifacts
    await prebuildAllArtifacts();

    verboseLog(`[E2E] Checking if server binary exists...`);
    if (await checkServerBinary(binaryType)) {
        verboseLog(`[E2E] Server binary (${binaryType}) is available`);
        return;
    }

    throw new Error(
        `Server binary (${binaryType}) missing after prebuild. Run "zig build -Dwith-libev=true" and retry.`,
    );
}
