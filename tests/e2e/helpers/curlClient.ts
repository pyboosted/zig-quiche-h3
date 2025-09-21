import { spawn } from "bun";
import { waitForProcessExit } from "./testUtils";

/**
 * Structured response from curl
 */
export interface CurlResponse {
    status: number;
    statusText: string;
    headers: Map<string, string>;
    body: Uint8Array;
    raw: string;
}

/**
 * Options for curl requests
 */
export interface CurlOptions {
    method?: "GET" | "POST" | "HEAD" | "DELETE" | "PUT" | "PATCH";
    headers?: Record<string, string>;
    body?: string | Uint8Array | File | undefined;
    bodyFilePath?: string; // Path to file for --data-binary @<path>
    outputNull?: boolean; // Use /dev/null for body (headers only)
    limitRate?: string; // e.g., "50k" for rate limiting
    maxTime?: number; // Timeout in seconds
    followRedirects?: boolean;
}

/**
 * Make an HTTP/3 request using curl
 */
export async function curl(url: string, options: CurlOptions = {}): Promise<CurlResponse> {
    const args = [
        "curl",
        "-sk", // Silent, insecure (accept self-signed certs)
        "--http3-only", // Force HTTP/3
        "-i", // Include headers in output
        "--raw", // Disable HTTP decoding of content
    ];

    // Method
    if (options.method && options.method !== "GET") {
        args.push("-X", options.method);
    }

    // Headers
    if (options.headers) {
        for (const [key, value] of Object.entries(options.headers)) {
            args.push("-H", `${key}: ${value}`);
        }
    }

    // Body
    if (options.bodyFilePath) {
        args.push("--data-binary", `@${options.bodyFilePath}`);
    } else if (options.body) {
        if (typeof options.body === "string") {
            args.push("--data-raw", options.body);
        } else if (options.body instanceof Uint8Array) {
            // For binary data, write to temp file and use --data-binary
            const tempFile = `./tmp/e2e/curl-${Date.now()}.bin`;
            await Bun.write(tempFile, options.body);
            args.push("--data-binary", `@${tempFile}`);
        } else if (options.body instanceof File) {
            // Write File contents to temp file
            const tempFile = `./tmp/e2e/curl-${Date.now()}-${options.body.name}`;
            await Bun.write(tempFile, await options.body.arrayBuffer());
            args.push("--data-binary", `@${tempFile}`);
        }
    }

    // Output options
    if (options.outputNull) {
        args.push("--output", "/dev/null");
        args.push("--dump-header", "-"); // Headers to stdout
    }

    // Rate limiting
    if (options.limitRate) {
        args.push("--limit-rate", options.limitRate);
    }

    // Timeout
    if (options.maxTime) {
        args.push("--max-time", options.maxTime.toString());
    }

    // Follow redirects
    if (options.followRedirects) {
        args.push("-L");
    }

    // URL last
    args.push(url);

    // Execute curl
    const proc = spawn({
        cmd: args,
        stdout: "pipe",
        stderr: "pipe",
    });

    // Wait for process with timeout (add 1s buffer to curl timeout)
    const timeoutMs = (options.maxTime || 30) * 1000 + 1000;
    await waitForProcessExit(proc, timeoutMs);

    if (proc.exitCode !== 0) {
        const stderr = await new Response(proc.stderr).text();
        throw new Error(`Curl failed with exit code ${proc.exitCode}: ${stderr}`);
    }

    // Read stdout as raw bytes to preserve binary data
    const rawBytes = new Uint8Array(await new Response(proc.stdout).arrayBuffer());

    // Parse response
    return parseResponse(rawBytes, options.outputNull);
}

/**
 * Parse curl response bytes into structured format
 */
function parseResponse(rawBytes: Uint8Array, headersOnly = false): CurlResponse {
    const headers = new Map<string, string>();
    let status = 0;
    let statusText = "";

    // Find the end of headers (\r\n\r\n or \n\n)
    const headerEnd = findHeaderEnd(rawBytes);
    if (headerEnd === -1) {
        throw new Error("Could not find end of HTTP headers");
    }

    // Decode headers as UTF-8 text (ASCII is a subset)
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
            headers.set(key, value);
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
    options?: Omit<CurlOptions, "method">,
): Promise<CurlResponse> {
    return curl(url, { ...options, method: "GET" });
}

/**
 * Quick POST request helper
 */
export async function post(
    url: string,
    body?: string | Uint8Array | File,
    options?: Omit<CurlOptions, "method" | "body">,
): Promise<CurlResponse> {
    return curl(url, { ...options, method: "POST", body });
}

/**
 * Quick HEAD request helper
 */
export async function head(
    url: string,
    options?: Omit<CurlOptions, "method">,
): Promise<CurlResponse> {
    return curl(url, { ...options, method: "HEAD" });
}

/**
 * Check if curl has HTTP/3 support
 */
export async function checkHttp3Support(): Promise<boolean> {
    try {
        const proc = spawn({
            cmd: ["curl", "--version"],
            stdout: "pipe",
            stderr: "pipe",
        });
        await waitForProcessExit(proc, 5000);

        if (proc.exitCode !== 0) return false;

        const output = await new Response(proc.stdout).text();
        return output.includes("HTTP3") || output.includes("quiche") || output.includes("nghttp3");
    } catch {
        return false;
    }
}
