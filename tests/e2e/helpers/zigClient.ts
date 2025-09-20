import { spawn } from "bun";
import { join } from "path";
import type { CurlOptions, CurlResponse } from "./curlClient";
import { getProjectRoot } from "./testUtils";

/**
 * Extended options for zigClient that support H3 DATAGRAMs and concurrent requests
 */
export interface ZigClientResponse extends CurlResponse {
    responses?: CurlResponse[];
}

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
    includeHeaders?: boolean;
    outputBody?: boolean;
    json?: boolean;
    insecure?: boolean;
    verifyPeer?: boolean;
}

/**
 * Make an HTTP/3 request using our native h3-client client
 * This is a drop-in replacement for curl with extended features
 */
export async function zigClient(
    url: string,
    options: ZigClientOptions = {},
): Promise<ZigClientResponse> {
    // Use absolute path to h3-client binary
    const projectRoot = getProjectRoot();
    const h3ClientPath = join(projectRoot, "zig-out", "bin", "h3-client");
    const args = [h3ClientPath];

    // URL is required
    args.push("--url", url);

    // Always enable curl compatibility mode for test output
    const useCurlCompat = options.curlCompat !== false;
    if (useCurlCompat) {
        args.push("--curl-compat");
    }

    // Include headers in output (curl -i)
    if (useCurlCompat && options.outputNull !== true && options.includeHeaders !== false) {
        args.push("--include-headers");
    } else if (!useCurlCompat && options.includeHeaders === true) {
        args.push("--include-headers");
    }

    // Silent mode (suppress debug output)
    args.push("--silent");

    // Insecure mode for self-signed certs
    if (options.insecure !== false) {
        args.push("--insecure");
    }
    if (options.verifyPeer) {
        args.push("--verify-peer");
    }

    if (options.json) {
        args.push("--json");
    }
    if (options.outputBody === false) {
        args.push("--output-body=false");
    }

    // Method
    if (options.method && options.method !== "GET") {
        args.push("--method", options.method);
    }

    // Headers
    let contentLength: number | undefined;
    if (typeof options.body === "string") {
        contentLength = new TextEncoder().encode(options.body).length;
    } else if (options.body instanceof Uint8Array) {
        contentLength = options.body.length;
    } else if (options.body instanceof File) {
        contentLength = options.body.size;
    }

    const headerList: string[] = [];
    let hasContentLength = false;
    if (options.headers) {
        for (const [key, value] of Object.entries(options.headers)) {
            const headerValue = String(value);
            if (key.toLowerCase() === "content-length") {
                hasContentLength = true;
            }
            headerList.push(`${key}:${headerValue}`);
        }
    }
    if (!hasContentLength && contentLength !== undefined) {
        headerList.push(`content-length:${contentLength}`);
    }
    if (headerList.length > 0) {
        args.push("--headers", headerList.join(","));
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

    // Execute h3-client
    const proc = spawn({
        cmd: args,
        stdout: "pipe",
        stderr: "pipe",
        env,
    });

    await proc.exited;

    if (proc.exitCode !== 0) {
        const stderr = await new Response(proc.stderr).text();
        throw new Error(`h3-client failed with exit code ${proc.exitCode}: ${stderr}`);
    }

    // Read stdout as raw bytes to preserve binary data
    const rawBytes = new Uint8Array(await new Response(proc.stdout).arrayBuffer());

    // Parse response using the same format as curl
    return parseResponse(rawBytes, options.outputNull === true);
}

/**
 * Parse h3-client response bytes into structured format
 * The output format matches curl with --include-headers flag
 */
function parseResponse(rawBytes: Uint8Array, headersOnly = false): ZigClientResponse {
    const multi = parseMultipleResponses(rawBytes, headersOnly);
    if (multi) {
        const decoder = new TextDecoder("utf-8", { fatal: false });
        const rawText = decoder.decode(rawBytes);
        const primary = { ...multi[0] };
        primary.raw = rawText;
        return { ...primary, responses: multi };
    }

    return parseSingleResponse(rawBytes, headersOnly);
}

function parseMultipleResponses(rawBytes: Uint8Array, headersOnly: boolean): CurlResponse[] | null {
    const marker = new TextEncoder().encode("HTTP/3 ");
    if (rawBytes.length < marker.length) return null;

    const starts: number[] = [];
    outer: for (let i = 0; i <= rawBytes.length - marker.length; i++) {
        for (let j = 0; j < marker.length; j++) {
            if (rawBytes[i + j] !== marker[j]) {
                continue outer;
            }
        }
        starts.push(i);
    }

    if (starts.length <= 1) return null;

    const responses: CurlResponse[] = [];
    for (let idx = 0; idx < starts.length; idx++) {
        const start = starts[idx]!;
        const end = idx + 1 < starts.length ? starts[idx + 1]! : rawBytes.length;
        const slice = rawBytes.slice(start, end);
        responses.push(parseSingleResponse(slice, headersOnly));
    }

    return responses;
}

function parseSingleResponse(rawBytes: Uint8Array, headersOnly = false): CurlResponse {
    const headers = new Map<string, string>();
    let status = 0;
    let statusText = "";

    // First, find where the actual HTTP response starts (skip debug logs)
    const httpMarker = new TextEncoder().encode("HTTP/3 ");
    let httpStart = -1;

    // Search for "HTTP/3 " in the raw bytes
    for (let i = 0; i <= rawBytes.length - httpMarker.length; i++) {
        let match = true;
        for (let j = 0; j < httpMarker.length; j++) {
            if (rawBytes[i + j] !== httpMarker[j]) {
                match = false;
                break;
            }
        }
        if (match) {
            httpStart = i;
            break;
        }
    }

    // If no HTTP/3 response found, treat as raw body
    if (httpStart === -1) {
        return {
            status: 200,
            statusText: "OK",
            headers: new Map(),
            body: rawBytes,
            raw: new TextDecoder("utf-8", { fatal: false }).decode(rawBytes),
        };
    }

    // Work with bytes starting from HTTP/3
    const responseBytes = rawBytes.slice(httpStart);

    // Parse headers line by line to find the blank line separator
    let headerEndPos = -1;
    const _currentPos = 0;
    let _foundStatusLine = false;
    const _lineStart = 0;

    // Convert to string for easier line-by-line parsing
    const responseText = new TextDecoder("utf-8").decode(responseBytes);
    const lines = responseText.split(/\r?\n/);

    let _headerLineCount = 0;
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];

        // First line should be status line
        if (i === 0) {
            if (line.startsWith("HTTP/3 ")) {
                const match = line.match(/^HTTP\/3\s+(\d+)\s*(.*)$/);
                if (match) {
                    status = Number.parseInt(match[1]!, 10);
                    statusText = match[2]!.trim();
                    _foundStatusLine = true;
                }
            }
            _headerLineCount++;
            continue;
        }

        // Empty line indicates end of headers
        if (line.trim() === "") {
            // Calculate byte position of header end
            // Sum up byte lengths of all header lines plus line endings
            let bytePos = 0;
            for (let j = 0; j <= i; j++) {
                bytePos += new TextEncoder().encode(lines[j]).length;
                if (j < i) {
                    // Add line ending bytes (check if \r\n or \n)
                    const lineEndingBytes = responseText.includes("\r\n") ? 2 : 1;
                    bytePos += lineEndingBytes;
                }
            }
            headerEndPos = bytePos;
            break;
        }

        // Parse header line
        const colonIndex = line.indexOf(":");
        if (colonIndex > 0) {
            const key = line.slice(0, colonIndex).trim().toLowerCase();
            const value = line.slice(colonIndex + 1).trim();
            // Skip pseudo-headers like :status
            if (!key.startsWith(":")) {
                headers.set(key, value);
            }
        }
        _headerLineCount++;
    }

    // Extract body as raw bytes
    let body: Uint8Array = new Uint8Array(0);
    if (!headersOnly && headerEndPos !== -1) {
        // Skip the blank line separator
        const lineEndingBytes = responseText.includes("\r\n") ? 2 : 1;
        // headerEndPos is relative to responseBytes/responseText, so we need to add it to httpStart
        const bodyStartIndex = httpStart + headerEndPos + lineEndingBytes;

        if (bodyStartIndex < rawBytes.length) {
            // Extract body, but also check for trailing debug messages
            let bodyEndIndex = rawBytes.length;

            // Look for common trailing debug messages and exclude them
            const warningMarker = new TextEncoder().encode(
                "Warning: Failed to disable debug logging",
            );
            for (let i = bodyStartIndex; i <= rawBytes.length - warningMarker.length; i++) {
                let match = true;
                for (let j = 0; j < warningMarker.length; j++) {
                    if (rawBytes[i + j] !== warningMarker[j]) {
                        match = false;
                        break;
                    }
                }
                if (match) {
                    // Found warning message, exclude it from body
                    bodyEndIndex = i;
                    // Remove trailing newline before warning if present
                    if (bodyEndIndex > bodyStartIndex && rawBytes[bodyEndIndex - 1] === 0x0a) {
                        bodyEndIndex--;
                        if (bodyEndIndex > bodyStartIndex && rawBytes[bodyEndIndex - 1] === 0x0d) {
                            bodyEndIndex--;
                        }
                    }
                    break;
                }
            }

            body = rawBytes.slice(bodyStartIndex, bodyEndIndex);
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
function _findHeaderEnd(bytes: Uint8Array): number {
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
): Promise<ZigClientResponse> {
    return zigClient(url, { ...options, method: "GET" });
}

/**
 * Quick POST request helper
 */
export async function post(
    url: string,
    body?: string | Uint8Array | File,
    options?: Omit<ZigClientOptions, "method" | "body">,
): Promise<ZigClientResponse> {
    return zigClient(url, { ...options, method: "POST", body });
}

/**
 * Quick HEAD request helper
 */
export async function head(
    url: string,
    options?: Omit<ZigClientOptions, "method">,
): Promise<ZigClientResponse> {
    return zigClient(url, { ...options, method: "HEAD" });
}

/**
 * Backward compatibility: export zigClient as curl
 */
export const curl = zigClient;

/**
 * Check if h3-client binary exists
 */
export async function checkH3CliSupport(): Promise<boolean> {
    try {
        const proc = spawn({
            cmd: ["./zig-out/bin/h3-client", "--help"],
            stdout: "pipe",
            stderr: "pipe",
        });
        await proc.exited;
        return proc.exitCode === 0;
    } catch {
        return false;
    }
}
