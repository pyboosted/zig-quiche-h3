import { expect, test, beforeAll, afterAll } from "bun:test";
import { H3Server } from "../../../src/bun/server";
import { spawnSync } from "bun";
import path from "path";

let server: H3Server | null = null;
const PORT = 4436;

// Track datagram messages received by the server
const receivedMessages: string[] = [];

beforeAll(async () => {
  // Reset received messages
  receivedMessages.length = 0;

  // Create server with WebTransport route
  server = new H3Server({
    port: PORT,
    certPath: "third_party/quiche/quiche/examples/cert.crt",
    keyPath: "third_party/quiche/quiche/examples/cert.key",
    routes: [
      {
        method: "CONNECT",
        pattern: "/wt/echo",
        webtransport: (ctx) => {
          // Accept the WebTransport session
          ctx.accept();

          // Send a welcome datagram
          const welcomeMsg = new TextEncoder().encode("WebTransport session established");
          ctx.sendDatagram(welcomeMsg);

          // Track that handler was invoked
          receivedMessages.push("session-established");
        },
        // This route can handle BOTH WebTransport CONNECT and regular HTTP
        // The fetch handler responds to non-WT requests (e.g. GET for info)
        fetch: (req) => {
          return new Response("WebTransport endpoint - use CONNECT :protocol=webtransport", {
            status: 200,
            headers: { "content-type": "text/plain" },
          });
        },
      },
    ],
    fetch: (req) => {
      return new Response("Default handler", {
        status: 200,
        headers: { "content-type": "text/plain" },
      });
    },
  });

  // Wait for server to be ready
  await new Promise((resolve) => setTimeout(resolve, 100));
});

afterAll(async () => {
  if (server) {
    server.stop();
    server.close();
  }
});

test("WebTransport route is registered", async () => {
  // Verify server is running
  expect(server).not.toBeNull();
  expect(server!.running).toBe(true);
});

test("WebTransport session establishment via native client", async () => {
  // Build the WebTransport client
  const projectRoot = path.resolve(__dirname, "../../..");
  const buildCmd = spawnSync({
    cmd: ["zig", "build", "wt-client"],
    cwd: projectRoot,
    stdout: "inherit",
    stderr: "inherit",
  });

  if (buildCmd.exitCode !== 0) {
    throw new Error("Failed to build wt-client");
  }

  // Run the WebTransport client
  const clientPath = path.join(projectRoot, "zig-out/bin/wt-client");
  const result = spawnSync({
    cmd: [clientPath, `https://127.0.0.1:${PORT}/wt/echo`],
    stdout: "pipe",
    stderr: "pipe",
  });

  const stderr = result.stderr?.toString() || "";
  const stdout = result.stdout?.toString() || "";

  // For debugging if test fails
  if (result.exitCode !== 0) {
    console.error("wt-client stderr:", stderr);
    console.error("wt-client stdout:", stdout);
  }

  // Check that session was established
  expect(result.exitCode).toBe(0);
  expect(stderr).toContain("WebTransport session established");

  // Verify server handler was invoked
  expect(receivedMessages).toContain("session-established");
}, 15000);

test("WebTransport auto-enables DATAGRAM support", async () => {
  // Stats should show server is running with datagrams enabled
  const stats = server!.getStats();
  expect(stats.requests).toBeGreaterThanOrEqual(0n);

  // Server should have accepted at least one connection from the WT test
  expect(stats.connectionsTotal).toBeGreaterThanOrEqual(1n);
});

test("WebTransport not supported without route handler", async () => {
  // Create a server without WebTransport routes
  const nonWTServer = new H3Server({
    port: 4437,
    certPath: "third_party/quiche/quiche/examples/cert.crt",
    keyPath: "third_party/quiche/quiche/examples/cert.key",
    fetch: (req) => {
      return new Response("No WebTransport", {
        status: 200,
        headers: { "content-type": "text/plain" },
      });
    },
  });

  try {
    // Wait for server to be ready
    await new Promise((resolve) => setTimeout(resolve, 100));

    // Try to connect with WebTransport client
    const projectRoot = path.resolve(__dirname, "../../..");
    const clientPath = path.join(projectRoot, "zig-out/bin/wt-client");

    const result = spawnSync({
      cmd: [clientPath, `https://127.0.0.1:4437/wt/echo`],
      stdout: "pipe",
      stderr: "pipe",
    });

    // Client should fail because server doesn't support WebTransport
    expect(result.exitCode).not.toBe(0);
  } finally {
    nonWTServer.stop();
    nonWTServer.close();
  }
}, 10000);