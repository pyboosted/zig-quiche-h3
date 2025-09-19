import { spawn } from "bun";
import { join } from "path";
import type { CurlOptions, CurlResponse } from "./curlClient";
import { getProjectRoot } from "./testUtils";

/**
 * Extended options for zigClient that support H3 DATAGRAMs and concurrent requests
 */
export interface ZigClientOptions extends CurlOptions {
    // Extended options beyond curl
    h3Dgram?: boolean;
    dgramPayload?: string;
    dgramPayloadFile?: string;
    dgramCount?: number;
    dgramIntervalMs?: number;
    dgramWaitMs?: number;
    webTransport?: boolean;
    concurrent?: number;
    poolConnections?: boolean;
    curlCompat?: boolean;
}

/**
 * Make an HTTP/3 request using our native h3-cli client
 * This is a drop-in replacement for curl with extended features
 */
export async function zigClient(url: string, options: ZigClientOptions = {}): Promise<CurlResponse> {
    // Use absolute path to h3-cli binary
    const projectRoot = getProjectRoot();
    const h3CliPath = join(projectRoot, "zig-out", "bin", "h3-cli");
    const args = [h3CliPath];

    // URL is required
    args.push("--url", url);

    // Always enable curl compatibility mode for test output
    if (options.curlCompat !== false) {
        args.push("--curl-compat");
    }

    // Include headers in output (curl -i)
    if (options.outputNull !== true) {
        args.push("--include-headers");
    }

    // Silent mode (suppress debug output)
    args.push("--silent");

    // Insecure mode for self-signed certs
    args.push("--insecure");

    // Method
    if (options.method && options.method !== "GET") {
        args.push("--method", options.method);
    }

    // Headers
    if (options.headers) {
        const headerList: string[] = [];
        for (const [key, value] of Object.entries(options.headers)) {
            headerList.push(`${key}:${value}`);
        }
        if (headerList.length > 0) {
            args.push("--headers", headerList.join(","));
        }
    }

    // Body
    if (options.bodyFilePath) {
        args.push("--body-file", options.bodyFilePath);
    } else if (options.body) {
        if (typeof options.body === "string") {
            args.push("--body", options.body);
        } else if (options.body instanceof Uint8Array) {
            // For binary data, write to temp file
            const tempFile = `./tmp/e2e/zig-${Date.now()}.bin`;
            await Bun.write(tempFile, options.body);
            args.push("--body-file", tempFile);
        } else if (options.body instanceof File) {
            // Write File contents to temp file
            const tempFile = `./tmp/e2e/zig-${Date.now()}-${options.body.name}`;
            await Bun.write(tempFile, await options.body.arrayBuffer());
            args.push("--body-file", tempFile);
        }
    }

    // Rate limiting
    if (options.limitRate) {
        args.push("--limit-rate", options.limitRate);
        args.push("--stream"); // Rate limiting requires streaming
    }

    // Timeout
    if (options.maxTime) {
        args.push("--timeout-ms", (options.maxTime * 1000).toString());
    }

    // Extended H3 DATAGRAM options
    if (options.h3Dgram || options.dgramCount) {
        args.push("--stream"); // DATAGRAMs require streaming

        if (options.dgramPayload) {
            args.push("--dgram-payload", options.dgramPayload);
        }
        if (options.dgramPayloadFile) {
            args.push("--dgram-payload-file", options.dgramPayloadFile);
        }
        if (options.dgramCount) {
            args.push("--dgram-count", options.dgramCount.toString());
        }
        if (options.dgramIntervalMs) {
            args.push("--dgram-interval-ms", options.dgramIntervalMs.toString());
        }
        if (options.dgramWaitMs) {
            args.push("--dgram-wait-ms", options.dgramWaitMs.toString());
        }
    }

    // WebTransport
    if (options.webTransport) {
        args.push("--enable-webtransport");
    }

    // Concurrent requests
    if (options.concurrent && options.concurrent > 1) {
        args.push("--repeat", options.concurrent.toString());
    }

    // Output to file or null
    let outputFile: string | undefined;
    if (options.outputNull) {
        outputFile = "/dev/null";
        args.push("--output", outputFile);
        args.push("--output-body", "false");
    }

    // Add RUST_LOG=error to suppress quiche debug output
    const env = {
        ...process.env,
        RUST_LOG: "error",
    };

    // Execute h3-cli
    const proc = spawn({
        cmd: args,
        stdout: "pipe",
        stderr: "pipe",
        env,
    });

    await proc.exited;

    if (proc.exitCode !== 0) {
        const stderr = await new Response(proc.stderr).text();
        throw new Error(`h3-cli failed with exit code ${proc.exitCode}: ${stderr}`);
    }

    // Read stdout as raw bytes to preserve binary data
    const rawBytes = new Uint8Array(await new Response(proc.stdout).arrayBuffer());

    // Parse response using the same format as curl
    return parseResponse(rawBytes, options.outputNull);
}

/**
 * Parse h3-cli response bytes into structured format
 * The output format matches curl with --include-headers flag
 */
function parseResponse(rawBytes: Uint8Array, headersOnly = false): CurlResponse {
    const headers = new Map<string, string>();
    let status = 0;
    let statusText = "";

    // Find the end of headers (\r\n\r\n or \n\n)
    const headerEnd = findHeaderEnd(rawBytes);
    if (headerEnd === -1) {
        // If no headers found, treat entire response as body
        return {
            status: 200, // Assume success if no status line
            statusText: "OK",
            headers: new Map(),
            body: rawBytes,
            raw: new TextDecoder("utf-8", { fatal: false }).decode(rawBytes),
        };
    }

    // Decode headers as UTF-8 text
    const headerBytes = rawBytes.slice(0, headerEnd);
    const headerText = new TextDecoder("utf-8").decode(headerBytes);
    const lines = headerText.split(/\r?\n/);

    // Parse status line and headers
    for (const line of lines) {
        const trimmedLine = line.trim();

        // Status line (HTTP/3 200 OK)
        if (trimmedLine.startsWith("HTTP/3 ")) {
            const match = trimmedLine.match(/^HTTP\/3\s+(\d+)\s*(.*)$/);
            if (match) {
                status = Number.parseInt(match[1]!, 10);
                statusText = match[2]!.trim();
            }
            continue;
        }

        // Header line
        const colonIndex = trimmedLine.indexOf(":");
        if (colonIndex > 0) {
            const key = trimmedLine.slice(0, colonIndex).trim().toLowerCase();
            const value = trimmedLine.slice(colonIndex + 1).trim();
            // Skip pseudo-headers like :status
            if (!key.startsWith(":")) {
                headers.set(key, value);
            }
        }
    }

    // Extract body as raw bytes
    let body: Uint8Array = new Uint8Array(0);
    if (!headersOnly) {
        // Skip the header separator (\r\n\r\n or \n\n)
        const separatorLength = rawBytes[headerEnd] === 0x0d ? 4 : 2; // \r\n\r\n vs \n\n

        const bodyStartIndex = headerEnd + separatorLength;
        if (bodyStartIndex < rawBytes.length) {
            body = rawBytes.slice(bodyStartIndex);
        }
    }

    return {
        status,
        statusText,
        headers,
        body,
        raw: new TextDecoder("utf-8", { fatal: false }).decode(rawBytes),
    };
}

/**
 * Find the end of HTTP headers in raw bytes
 */
function findHeaderEnd(bytes: Uint8Array): number {
    // Look for \r\n\r\n (0x0d 0x0a 0x0d 0x0a)
    for (let i = 0; i < bytes.length - 3; i++) {
        if (
            bytes[i] === 0x0d &&
            bytes[i + 1] === 0x0a &&
            bytes[i + 2] === 0x0d &&
            bytes[i + 3] === 0x0a
        ) {
            return i;
        }
    }

    // Look for \n\n (0x0a 0x0a)
    for (let i = 0; i < bytes.length - 1; i++) {
        if (bytes[i] === 0x0a && bytes[i + 1] === 0x0a) {
            return i;
        }
    }

    return -1;
}

/**
 * Quick GET request helper
 */
export async function get(
    url: string,
    options?: Omit<ZigClientOptions, "method">,
): Promise<CurlResponse> {
    return zigClient(url, { ...options, method: "GET" });
}

/**
 * Quick POST request helper
 */
export async function post(
    url: string,
    body?: string | Uint8Array | File,
    options?: Omit<ZigClientOptions, "method" | "body">,
): Promise<CurlResponse> {
    return zigClient(url, { ...options, method: "POST", body });
}

/**
 * Quick HEAD request helper
 */
export async function head(
    url: string,
    options?: Omit<ZigClientOptions, "method">,
): Promise<CurlResponse> {
    return zigClient(url, { ...options, method: "HEAD" });
}

/**
 * Backward compatibility: export zigClient as curl
 */
export const curl = zigClient;

/**
 * Check if h3-cli binary exists
 */
export async function checkH3CliSupport(): Promise<boolean> {
    try {
        const proc = spawn({
            cmd: ["./zig-out/bin/h3-cli", "--help"],
            stdout: "pipe",
            stderr: "pipe",
        });
        await proc.exited;
        return proc.exitCode === 0;
    } catch {
        return false;
    }
}