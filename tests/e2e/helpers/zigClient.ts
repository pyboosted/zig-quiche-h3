import { spawn } from "bun";
import { join } from "path";
import type { CurlOptions, CurlResponse } from "./curlClient";
import { getProjectRoot, waitForProcessExit } from "./testUtils";

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
    waitForDgrams?: number;
}

/**
 * Make an HTTP/3 request using our native h3-client client
 * This is a drop-in replacement for curl with extended features
 */
export async function zigClient(
    url: string,
    options: ZigClientOptions = {},
): Promise<ZigClientResponse> {
    // Set default timeout to 5 seconds if not specified
    const optionsWithTimeout = {
        maxTime: 5, // Default 5 second timeout
        ...options, // Allow override if specified
    };

    // Use absolute path to h3-client binary
    const projectRoot = getProjectRoot();
    const h3ClientPath = join(projectRoot, "zig-out", "bin", "h3-client");
    const args = [h3ClientPath];

    // URL is required
    args.push("--url", url);

    // Always enable curl compatibility mode for test output
    const useCurlCompat = optionsWithTimeout.curlCompat !== false;
    if (useCurlCompat) {
        args.push("--curl-compat");
    }

    // Include headers in output (curl -i)
    if (
        useCurlCompat &&
        optionsWithTimeout.outputNull !== true &&
        optionsWithTimeout.includeHeaders !== false
    ) {
        args.push("--include-headers");
    } else if (!useCurlCompat && optionsWithTimeout.includeHeaders === true) {
        args.push("--include-headers");
    }

    // Silent mode (suppress debug output)
    args.push("--silent");

    // Insecure mode for self-signed certs
    if (optionsWithTimeout.insecure !== false) {
        args.push("--insecure");
    }
    if (optionsWithTimeout.verifyPeer) {
        args.push("--verify-peer");
    }

    if (optionsWithTimeout.json) {
        args.push("--json");
    }
    if (optionsWithTimeout.outputBody === false) {
        args.push("--output-body=false");
    }

    // Method
    if (optionsWithTimeout.method && optionsWithTimeout.method !== "GET") {
        args.push("--method", optionsWithTimeout.method);
    }

    // Headers
    let contentLength: number | undefined;
    if (typeof optionsWithTimeout.body === "string") {
        contentLength = new TextEncoder().encode(optionsWithTimeout.body).length;
    } else if (optionsWithTimeout.body instanceof Uint8Array) {
        contentLength = optionsWithTimeout.body.length;
    } else if (optionsWithTimeout.body instanceof File) {
        contentLength = optionsWithTimeout.body.size;
    }

    const headerList: string[] = [];
    let hasContentLength = false;
    if (optionsWithTimeout.headers) {
        for (const [key, value] of Object.entries(optionsWithTimeout.headers)) {
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
        args.push("--headers", headerList.join("\n"));
    }

    // Body
    if (optionsWithTimeout.bodyFilePath) {
        args.push("--body-file", optionsWithTimeout.bodyFilePath);
    } else if (optionsWithTimeout.body) {
        if (typeof optionsWithTimeout.body === "string") {
            args.push("--body", optionsWithTimeout.body);
        } else if (optionsWithTimeout.body instanceof Uint8Array) {
            // For binary data, write to temp file
            const tempFile = `./tmp/e2e/zig-${Date.now()}.bin`;
            await Bun.write(tempFile, optionsWithTimeout.body);
            args.push("--body-file", tempFile);
        } else if (optionsWithTimeout.body instanceof File) {
            // Write File contents to temp file
            const tempFile = `./tmp/e2e/zig-${Date.now()}-${optionsWithTimeout.body.name}`;
            await Bun.write(tempFile, await optionsWithTimeout.body.arrayBuffer());
            args.push("--body-file", tempFile);
        }
    }

    // Rate limiting
    if (optionsWithTimeout.limitRate) {
        args.push("--limit-rate", optionsWithTimeout.limitRate);
        args.push("--stream"); // Rate limiting requires streaming
    }

    // Timeout
    if (optionsWithTimeout.maxTime) {
        args.push("--timeout-ms", (optionsWithTimeout.maxTime * 1000).toString());
    }

    // Extended H3 DATAGRAM options
    if (optionsWithTimeout.h3Dgram || optionsWithTimeout.dgramCount) {
        args.push("--stream"); // DATAGRAMs require streaming

        if (optionsWithTimeout.dgramPayload) {
            args.push("--dgram-payload", optionsWithTimeout.dgramPayload);
        }
        if (optionsWithTimeout.dgramPayloadFile) {
            args.push("--dgram-payload-file", optionsWithTimeout.dgramPayloadFile);
        }
        if (optionsWithTimeout.dgramCount) {
            args.push("--dgram-count", optionsWithTimeout.dgramCount.toString());
        }
        if (optionsWithTimeout.dgramIntervalMs) {
            args.push("--dgram-interval-ms", optionsWithTimeout.dgramIntervalMs.toString());
        }
        if (optionsWithTimeout.dgramWaitMs) {
            args.push("--dgram-wait-ms", optionsWithTimeout.dgramWaitMs.toString());
        }
        if (optionsWithTimeout.waitForDgrams && optionsWithTimeout.waitForDgrams > 0) {
            args.push("--wait-for-dgrams", optionsWithTimeout.waitForDgrams.toString());
        }
    }

    // WebTransport
    if (optionsWithTimeout.webTransport) {
        args.push("--enable-webtransport");
    }

    // Concurrent requests
    if (optionsWithTimeout.concurrent && optionsWithTimeout.concurrent > 1) {
        args.push("--repeat", optionsWithTimeout.concurrent.toString());
    }

    // Output to file or null
    let outputFile: string | undefined;
    if (optionsWithTimeout.outputNull) {
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

    // Wait for process with timeout (add 1s buffer to client timeout)
    const timeoutMs = (optionsWithTimeout.maxTime || 5) * 1000 + 1000;
    await waitForProcessExit(proc, timeoutMs);

    if (proc.exitCode !== 0) {
        const stderr = await new Response(proc.stderr).text();
        throw new Error(`h3-client failed with exit code ${proc.exitCode}: ${stderr}`);
    }

    // Read stdout as raw bytes to preserve binary data
    const rawBytes = new Uint8Array(await new Response(proc.stdout).arrayBuffer());

    // Parse response using the same format as curl
    return parseResponse(rawBytes, optionsWithTimeout.outputNull === true);
}

const HTTP_MARKER_BYTES = new TextEncoder().encode("HTTP/3 ");
const UTF8_DECODER = new TextDecoder("utf-8", { fatal: false });

/**
 * Parse h3-client response bytes into structured format
 * The output format matches curl with --include-headers flag
 */
function parseResponse(rawBytes: Uint8Array, headersOnly = false): ZigClientResponse {
    const multi = parseMultipleResponses(rawBytes, headersOnly);
    if (multi && multi.length > 0) {
        const rawText = UTF8_DECODER.decode(rawBytes);
        const primary = { ...multi[0]! };
        primary.raw = rawText;
        return { ...primary, responses: multi };
    }

    return parseSingleResponse(rawBytes, headersOnly);
}

function parseMultipleResponses(rawBytes: Uint8Array, headersOnly: boolean): CurlResponse[] | null {
    const firstMarker = indexOfSequence(rawBytes, HTTP_MARKER_BYTES);
    if (firstMarker === -1) return null;

    const responses: CurlResponse[] = [];
    let offset = firstMarker;

    while (offset >= 0 && offset < rawBytes.length) {
        const parsed = parseResponseAt(rawBytes, offset, headersOnly);
        if (!parsed) break;
        const { response, consumed } = parsed;
        response.raw = UTF8_DECODER.decode(rawBytes.slice(offset, offset + consumed));
        responses.push(response);

        offset += consumed;
        const nextMarker = indexOfSequence(rawBytes, HTTP_MARKER_BYTES, offset);
        if (nextMarker === -1) break;
        offset = nextMarker;
    }

    return responses.length > 1 ? responses : null;
}

function parseSingleResponse(rawBytes: Uint8Array, headersOnly = false): CurlResponse {
    const httpStart = indexOfSequence(rawBytes, HTTP_MARKER_BYTES);

    if (httpStart === -1) {
        return {
            status: 200,
            statusText: "OK",
            headers: new Map(),
            body: rawBytes,
            raw: UTF8_DECODER.decode(rawBytes),
        };
    }

    const parsed = parseResponseAt(rawBytes, httpStart, headersOnly);
    if (!parsed) {
        return {
            status: 200,
            statusText: "OK",
            headers: new Map(),
            body: rawBytes,
            raw: UTF8_DECODER.decode(rawBytes),
        };
    }

    const { response, consumed } = parsed;
    // Preserve any streaming event output that occurs before the HTTP block
    const prefix = httpStart > 0 ? UTF8_DECODER.decode(rawBytes.slice(0, httpStart)) : "";
    const httpText = UTF8_DECODER.decode(rawBytes.slice(httpStart, httpStart + consumed));
    response.raw = prefix + httpText;
    return response;
}

type ParsedResponse = { response: CurlResponse; consumed: number };

function parseResponseAt(
    rawBytes: Uint8Array,
    start: number,
    headersOnly: boolean,
): ParsedResponse | null {
    const headerBoundary = findHeaderBodyBoundary(rawBytes, start);
    if (headerBoundary <= start) return null;

    const headerBytes = rawBytes.slice(start, headerBoundary);
    const headerLines = UTF8_DECODER.decode(headerBytes).split(/\r?\n/);

    const headers = new Map<string, string>();
    let status = 200;
    let statusText = "";
    let contentLength: number | null = null;

    for (let i = 0; i < headerLines.length; i++) {
        const line = headerLines[i]!.trim();
        if (line.length === 0) continue;
        if (i === 0) {
            const match = line.match(/^HTTP\/3\s+(\d+)\s*(.*)$/);
            if (match) {
                status = Number.parseInt(match[1]!, 10);
                statusText = match[2]!.trim();
            }
            continue;
        }

        const colonIndex = line.indexOf(":");
        if (colonIndex <= 0) continue;
        const key = line.slice(0, colonIndex).trim().toLowerCase();
        if (key.startsWith(":")) continue;
        const value = line.slice(colonIndex + 1).trim();
        headers.set(key, value);
        if (key === "content-length") {
            const parsedLength = Number.parseInt(value, 10);
            if (Number.isFinite(parsedLength) && parsedLength >= 0) {
                contentLength = parsedLength;
            }
        }
    }

    const bodyStart = headerBoundary;
    let bodyEnd = rawBytes.length;

    if (contentLength !== null) {
        bodyEnd = Math.min(bodyStart + contentLength, rawBytes.length);
    } else {
        // When Content-Length is missing, look for the next HTTP/3 response marker
        // Search for "\nHTTP/3 " or "\r\nHTTP/3 " patterns (response directly follows body)
        const searchStart = bodyStart;

        // Look for LF followed by HTTP/3
        for (let i = searchStart; i < rawBytes.length - 6; i++) {
            if (rawBytes[i] === 0x0a && // LF
                rawBytes[i + 1] === 0x48 && rawBytes[i + 2] === 0x54 &&
                rawBytes[i + 3] === 0x54 && rawBytes[i + 4] === 0x50 &&
                rawBytes[i + 5] === 0x2f && rawBytes[i + 6] === 0x33) { // "HTTP/3"
                bodyEnd = i + 1; // Include the LF as part of the body
                break;
            }
        }

        // Also look for CRLF followed by HTTP/3
        if (bodyEnd === rawBytes.length) {
            for (let i = searchStart; i < rawBytes.length - 7; i++) {
                if (rawBytes[i] === 0x0d && rawBytes[i + 1] === 0x0a && // CRLF
                    rawBytes[i + 2] === 0x48 && rawBytes[i + 3] === 0x54 &&
                    rawBytes[i + 4] === 0x54 && rawBytes[i + 5] === 0x50 &&
                    rawBytes[i + 6] === 0x2f && rawBytes[i + 7] === 0x33) { // "HTTP/3"
                    bodyEnd = i + 2; // Include the CRLF as part of the body
                    break;
                }
            }
        }
    }

    const body = headersOnly ? new Uint8Array(0) : rawBytes.slice(bodyStart, bodyEnd);

    let nextOffset = bodyEnd;
    while (
        nextOffset < rawBytes.length &&
        (rawBytes[nextOffset] === 0x0a || rawBytes[nextOffset] === 0x0d)
    ) {
        nextOffset += 1;
    }

    return {
        response: {
            status,
            statusText,
            headers,
            body,
            raw: "",
        },
        consumed: nextOffset - start,
    };
}

function indexOfSequence(buffer: Uint8Array, sequence: Uint8Array, fromIndex = 0): number {
    outer: for (let i = fromIndex; i <= buffer.length - sequence.length; i++) {
        for (let j = 0; j < sequence.length; j++) {
            if (buffer[i + j] !== sequence[j]) {
                continue outer;
            }
        }
        return i;
    }
    return -1;
}

function findHeaderBodyBoundary(bytes: Uint8Array, start: number): number {
    const CR = 0x0d;
    const LF = 0x0a;
    for (let i = start; i + 3 < bytes.length; i++) {
        if (bytes[i] === CR && bytes[i + 1] === LF && bytes[i + 2] === CR && bytes[i + 3] === LF) {
            return i + 4;
        }
    }
    for (let i = start; i + 1 < bytes.length; i++) {
        if (bytes[i] === LF && bytes[i + 1] === LF) {
            return i + 2;
        }
    }
    return bytes.length;
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
        await waitForProcessExit(proc, 5000);
        return proc.exitCode === 0;
    } catch {
        return false;
    }
}
