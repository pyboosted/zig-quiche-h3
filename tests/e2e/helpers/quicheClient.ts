import { spawn } from "bun";

/**
 * Response from quiche-client
 */
export interface QuicheResponse {
  success: boolean;
  output: string;
  error?: string;
  statusCode?: number;
  headers?: Map<string, string>;
  body?: string;
}

/**
 * Options for quiche-client requests
 */
export interface QuicheClientOptions {
  method?: "GET" | "POST";
  headers?: Record<string, string>;
  body?: string | undefined;
  bodyFile?: string;
  maxActiveConnections?: number;
  requests?: number; // Number of concurrent requests
  dumpJson?: boolean;
  earlyData?: boolean;
  sessionFile?: string;
  dgramProto?: "none" | "oneway";
  dgramCount?: number;
}

/**
 * Make an HTTP/3 request using quiche-client
 */
export async function quicheClient(
  url: string,
  options: QuicheClientOptions = {},
): Promise<QuicheResponse> {
  const args = [
    "cargo",
    "run",
    "-p",
    "quiche_apps",
    "--bin",
    "quiche-client",
    "--",
    "--http-version",
    "HTTP/3",
    "--no-verify", // Accept self-signed certs
  ];

  // Dump JSON for easier parsing
  if (options.dumpJson !== false) {
    args.push("--dump-json");
  }

  // Method (only GET and POST supported)
  if (options.method === "POST") {
    // POST is implied when body/bodyFile is provided
  }

  // Headers
  if (options.headers) {
    for (const [key, value] of Object.entries(options.headers)) {
      args.push("-H", `${key}: ${value}`);
    }
  }

  // Body
  if (options.body) {
    // Write body to temp file
    const tempFile = `/tmp/quiche-body-${Date.now()}.txt`;
    await Bun.write(tempFile, options.body);
    args.push("--body", tempFile);
  } else if (options.bodyFile) {
    args.push("--body", options.bodyFile);
  }

  // Connection options
  if (options.maxActiveConnections) {
    args.push("--max-active-cids", options.maxActiveConnections.toString());
  }

  // Multiple requests
  if (options.requests && options.requests > 1) {
    args.push("--requests", options.requests.toString());
  }

  // Early data (0-RTT)
  if (options.earlyData) {
    args.push("--early-data");
  }

  // Session file for resumption
  if (options.sessionFile) {
    args.push("--session-file", options.sessionFile);
  }

  // DATAGRAM options (must be added before the URL)
  if (options.dgramProto && options.dgramProto !== "none") {
    args.push("--dgram-proto", options.dgramProto);
    if (options.dgramCount && options.dgramCount > 0) {
      args.push("--dgram-count", String(options.dgramCount));
    }
  }

  // URL
  args.push(url);

  // Execute quiche-client
  const proc = spawn({
    cmd: args,
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, RUST_LOG: "info" },
    cwd: "../third_party/quiche/", // Run from quiche directory
  });

  await proc.exited;

  const stdout = await new Response(proc.stdout).text();
  const stderr = await new Response(proc.stderr).text();

  const success = proc.exitCode === 0;

  if (!success) {
    return {
      success: false,
      output: stdout,
      error: stderr,
    };
  }

  // Parse output if JSON dump was requested
  if (options.dumpJson !== false) {
    try {
      const response = parseQuicheJsonOutput(stdout);
      return {
        success: true,
        output: stdout,
        error: stderr,
        ...response,
      };
    } catch (error) {
      console.warn("Failed to parse quiche JSON output:", error);
    }
  }

  return {
    success: true,
    output: stdout,
    error: stderr,
  };
}

/**
 * Parse quiche-client JSON output
 */
function parseQuicheJsonOutput(output: string): Partial<QuicheResponse> {
  // quiche-client outputs JSON lines, find the response
  const lines = output.split("\n");

  for (const line of lines) {
    if (line.trim().startsWith("{")) {
      try {
        const json = JSON.parse(line);

        // Extract useful information
        const headers = new Map<string, string>();
        if (json.headers && Array.isArray(json.headers)) {
          for (const header of json.headers) {
            if (header.name && header.value) {
              headers.set(header.name.toLowerCase(), header.value);
            }
          }
        }

        return {
          statusCode: json.status || json.status_code,
          headers,
          body: json.body || json.response_body,
        };
      } catch {}
    }
  }

  return {};
}

/**
 * Quick GET request using quiche-client
 */
export async function quicheGet(
  url: string,
  options?: Omit<QuicheClientOptions, "method">,
): Promise<QuicheResponse> {
  return quicheClient(url, { ...options, method: "GET" });
}

/**
 * Quick POST request using quiche-client
 */
export async function quichePost(
  url: string,
  body?: string,
  options?: Omit<QuicheClientOptions, "method" | "body">,
): Promise<QuicheResponse> {
  return quicheClient(url, { ...options, method: "POST", body });
}

/**
 * Check if quiche-client is available and working
 */
export async function checkQuicheClient(): Promise<boolean> {
  try {
    const proc = spawn({
      cmd: ["cargo", "run", "-p", "quiche_apps", "--bin", "quiche-client", "--", "--help"],
      stdout: "pipe",
      stderr: "pipe",
      cwd: "../third_party/quiche/",
    });
    await proc.exited;
    return proc.exitCode === 0;
  } catch {
    return false;
  }
}

/**
 * Build quiche apps if needed
 */
export async function ensureQuicheBuilt(): Promise<void> {
  if (await checkQuicheClient()) {
    return; // Already built
  }

  console.log("Building quiche apps...");

  const proc = spawn({
    cmd: ["cargo", "build", "--release", "--features", "ffi,qlog"],
    stdout: "pipe",
    stderr: "pipe",
    cwd: "../third_party/quiche/",
  });

  await proc.exited;

  if (proc.exitCode !== 0) {
    const stderr = await new Response(proc.stderr).text();
    throw new Error(`Quiche build failed: ${stderr}`);
  }

  console.log("Quiche built successfully");
}
