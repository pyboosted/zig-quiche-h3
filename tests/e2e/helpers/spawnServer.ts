import { type Subprocess, spawn } from "bun";
import { get } from "./zigClient";
import {
    checkDependencies,
    getCertPath,
    getProjectRoot,
    getServerBinary,
    randPort,
    ServerBinaryType,
    waitFor,
} from "./testUtils";

/**
 * Server instance with cleanup capability
 */
export interface ServerInstance {
    proc: Subprocess;
    port: number;
    cleanup: () => Promise<void>;
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
}

/**
 * Spawn the zig-quiche-h3 server and wait for it to be ready
 */
export async function spawnServer(opts: SpawnServerOptions = {}): Promise<ServerInstance> {
    console.log(`[E2E] spawnServer() started at ${new Date().toISOString()}`);
    const port =
        opts.port ?? (process.env.H3_TEST_PORT ? Number(process.env.H3_TEST_PORT) : randPort());
    console.log(`[E2E] Selected port: ${port}`);

    // Check dependencies first
    console.log(`[E2E] Checking dependencies at ${new Date().toISOString()}`);
    await checkDependencies();
    console.log(`[E2E] Dependencies checked at ${new Date().toISOString()}`);

    // Ensure server is built before attempting to spawn
    const binaryType = opts.binaryType || ServerBinaryType.Static;
    console.log(`[E2E] Calling ensureServerBuilt(${binaryType}) at ${new Date().toISOString()}`);
    await ensureServerBuilt(binaryType);
    console.log(`[E2E] ensureServerBuilt() completed at ${new Date().toISOString()}`);

    // Get paths using the new utilities - works from any directory
    const serverPath = getServerBinary(binaryType);
    const certPath = getCertPath("cert.crt");
    const keyPath = getCertPath("cert.key");

    // Build server arguments
    const args = [serverPath, "--port", port.toString(), "--cert", certPath, "--key", keyPath];

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

    console.log(`Spawning server on port ${port}...`);
    console.log(`[E2E] Server command: ${args.join(" ")}`);
    console.log(`[E2E] Working directory: ${getProjectRoot()}`);

    // Spawn the server process
    console.log(`[E2E] Calling spawn() at ${new Date().toISOString()}`);
    const proc = spawn({
        cmd: args,
        stdout: "pipe",
        stderr: "pipe",
        env,
        cwd: getProjectRoot(), // Run server from project root for consistent file resolution
    });
    console.log(`[E2E] Process spawned with PID: ${proc.pid} at ${new Date().toISOString()}`);

    // Create cleanup function
    const cleanup = async (): Promise<void> => {
        console.log(`Shutting down server on port ${port}...`);

        try {
            // Send SIGTERM for graceful shutdown
            proc.kill("SIGTERM");

            // Wait for graceful shutdown with timeout
            await Promise.race([
                proc.exited,
                Bun.sleep(2000), // 2 second timeout
            ]);

            // Force kill if still running
            if (!proc.killed) {
                proc.kill("SIGKILL");
                await proc.exited;
            }
        } catch (error) {
            console.warn(`Error during cleanup: ${error}`);
        }
    };

    // Wait for server to be ready
    const timeoutMs = opts.timeoutMs ?? 10000;
    const _deadline = Date.now() + timeoutMs;

    try {
        console.log(`[E2E] Waiting for server readiness at ${new Date().toISOString()}`);
        await waitFor(
            async () => {
                try {
                    // Use GET / for readiness probe (not HEAD as per audit)
                    console.log(
                        `[E2E] Probing https://127.0.0.1:${port}/ at ${new Date().toISOString()}`,
                    );
                    const response = await get(`https://127.0.0.1:${port}/`);
                    const ready = response.status === 200;
                    console.log(
                        `[E2E] Probe result: ${ready ? "ready" : "not ready"} (status: ${response.status})`,
                    );
                    return ready;
                } catch (err) {
                    console.log(`[E2E] Probe failed: ${err}`);
                    return false;
                }
            },
            timeoutMs,
            150,
        );

        console.log(`Server ready on port ${port}`);

        return {
            proc,
            port,
            cleanup,
        };
    } catch (error) {
        // Cleanup on startup failure
        await cleanup();

        // Try to get server logs for debugging
        let serverOutput = "";
        try {
            serverOutput = await new Response(proc.stderr).text();
        } catch {
            // Ignore
        }

        throw new Error(
            `Server failed to start within ${timeoutMs}ms. Error: ${error}${
                serverOutput ? `\n\nServer stderr:\n${serverOutput}` : ""
            }`,
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
    }
}

/**
 * Check if the server binary exists and is executable
 */
export async function checkServerBinary(
    binaryType: ServerBinaryType = ServerBinaryType.Static,
): Promise<boolean> {
    console.log(`[E2E] checkServerBinary(${binaryType}) started at ${new Date().toISOString()}`);
    try {
        const serverPath = getServerBinary(binaryType);
        console.log(`[E2E] Checking if server binary exists at: ${serverPath}`);

        // Simply check if the file exists - don't try to run it with --help
        // as the server doesn't support --help and will hang
        const exists = await Bun.file(serverPath).exists();
        console.log(`[E2E] Server binary (${binaryType}) exists: ${exists}`);
        return exists;
    } catch (err) {
        console.log(`[E2E] checkServerBinary() error: ${err}`);
        // Binary doesn't exist or isn't accessible
        return false;
    } finally {
        console.log(`[E2E] checkServerBinary() completed at ${new Date().toISOString()}`);
    }
}

/**
 * Build the server if needed
 */
export async function ensureServerBuilt(
    binaryType: ServerBinaryType = ServerBinaryType.Static,
): Promise<void> {
    console.log(`[E2E] ensureServerBuilt(${binaryType}) started at ${new Date().toISOString()}`);

    console.log(`[E2E] Checking if server binary exists...`);
    if (await checkServerBinary(binaryType)) {
        console.log(`[E2E] Server binary (${binaryType}) already exists, skipping build`);
        return; // Already built
    }

    console.log("Building server...");
    console.log(`[E2E] Server not found, starting build at ${new Date().toISOString()}`);

    const optimize = process.env.H3_OPTIMIZE ?? "ReleaseFast"; // ReleaseFast by default for perf tests
    const libevInclude =
        process.env.H3_LIBEV_INCLUDE ??
        (process.platform === "darwin" ? "/opt/homebrew/opt/libev/include" : undefined);
    const libevLib =
        process.env.H3_LIBEV_LIB ??
        (process.platform === "darwin" ? "/opt/homebrew/opt/libev/lib" : undefined);

    const args = ["zig", "build", "-Dwith-libev=true", `-Doptimize=${optimize}`];
    if (libevInclude) args.push(`-Dlibev-include=${libevInclude}`);
    if (libevLib) args.push(`-Dlibev-lib=${libevLib}`);

    // Always run from project root
    const projectRoot = getProjectRoot();

    console.log(`[E2E] Build command: ${args.join(" ")}`);
    console.log(`[E2E] Build directory: ${projectRoot}`);

    const proc = spawn({
        cmd: args,
        stdout: "pipe",
        stderr: "pipe",
        cwd: projectRoot,
    });
    console.log(`[E2E] Build process spawned, waiting for completion...`);

    await proc.exited;
    console.log(`[E2E] Build process exited with code: ${proc.exitCode}`);

    if (proc.exitCode !== 0) {
        const stderr = await new Response(proc.stderr).text();
        console.log(`[E2E] Build failed with stderr: ${stderr}`);
        throw new Error(`Server build failed: ${stderr}`);
    }

    console.log("Server built successfully");
    console.log(`[E2E] ensureServerBuilt() completed at ${new Date().toISOString()}`);
}
