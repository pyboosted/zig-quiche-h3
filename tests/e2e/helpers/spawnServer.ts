import { type Subprocess, spawn } from "bun";
import { get } from "./curlClient";
import { randPort, waitFor } from "./testUtils";

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
}

/**
 * Spawn the zig-quiche-h3 server and wait for it to be ready
 */
export async function spawnServer(opts: SpawnServerOptions = {}): Promise<ServerInstance> {
  const port =
    opts.port ?? (process.env.H3_TEST_PORT ? Number(process.env.H3_TEST_PORT) : randPort());

  // Ensure server is built before attempting to spawn
  await ensureServerBuilt();

  // Build server arguments
  const args = [
    "../../zig-out/bin/quic-server", // Relative to tests/e2e/ directory
    "--port",
    port.toString(),
    "--cert",
    "../../third_party/quiche/quiche/examples/cert.crt",
    "--key",
    "../../third_party/quiche/quiche/examples/cert.key",
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

  console.log(`Spawning server on port ${port}...`);

  // Spawn the server process
  const proc = spawn({
    cmd: args,
    stdout: "pipe",
    stderr: "pipe",
    env,
    cwd: "./", // Run from tests directory
  });

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
    await waitFor(
      async () => {
        try {
          // Use GET / for readiness probe (not HEAD as per audit)
          const response = await get(`https://127.0.0.1:${port}/`);
          return response.status === 200;
        } catch {
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
export async function checkServerBinary(): Promise<boolean> {
  try {
    const proc = spawn({
      cmd: ["../../zig-out/bin/quic-server", "--help"],
      stdout: "pipe",
      stderr: "pipe",
      cwd: "./",
    });
    await proc.exited;
    return proc.exitCode === 0;
  } catch {
    return false;
  }
}

/**
 * Build the server if needed
 */
export async function ensureServerBuilt(): Promise<void> {
  if (await checkServerBinary()) {
    return; // Already built
  }

  console.log("Building server...");

  const optimize = process.env.H3_OPTIMIZE ?? "ReleaseFast"; // ReleaseFast by default for perf tests
  const proc = spawn({
    cmd: ["zig", "build", "-Dwith-libev=true", "-Doptimize=" + optimize],
    stdout: "pipe",
    stderr: "pipe",
    cwd: "../", // Run from project root
  });

  await proc.exited;

  if (proc.exitCode !== 0) {
    const stderr = await new Response(proc.stderr).text();
    throw new Error(`Server build failed: ${stderr}`);
  }

  console.log("Server built successfully");
}
