import { FFIType, JSCallback, ptr, toArrayBuffer, type Pointer } from "bun:ffi";

import {
  getSymbols,
  hasServerSymbols,
  type ServerOnlySymbols,
  type ZigH3Symbols,
} from "./internal/library";

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();
type ServerSymbols = ZigH3Symbols & ServerOnlySymbols;

let serverSymbolsCache: ServerSymbols | null = null;
let headerStructSizeCache = 0;

function getServerSymbols(): ServerSymbols {
  if (serverSymbolsCache) return serverSymbolsCache;
  const rawSymbols: ZigH3Symbols = getSymbols();
  if (!hasServerSymbols(rawSymbols)) {
    throw new Error(
      "zig_h3 server symbols are not available. Rebuild libzigquicheh3 with server FFI exports enabled.",
    );
  }
  serverSymbolsCache = rawSymbols;
  headerStructSizeCache = Number(rawSymbols.zig_h3_header_size());
  return rawSymbols;
}

function requireHeaderStructSize(): number {
  if (headerStructSizeCache === 0) {
    getServerSymbols();
  }
  return headerStructSizeCache;
}

const DEFAULT_METHODS = [
  "GET",
  "POST",
  "PUT",
  "DELETE",
  "PATCH",
  "HEAD",
  "OPTIONS",
  "TRACE",
  "CONNECT",
  "CONNECT-UDP",
];

function makeCString(value: string | undefined): Uint8Array | null {
  if (!value) return null;
  const bytes = textEncoder.encode(value);
  const buf = new Uint8Array(bytes.length + 1);
  buf.set(bytes, 0);
  buf[bytes.length] = 0;
  return buf;
}

function decodeUtf8(ptrValue: number, len: number): string {
  if (ptrValue === 0 || len === 0) return "";
  const data = new Uint8Array(toArrayBuffer(pointerFrom(ptrValue), len));
  return textDecoder.decode(data);
}

function pointerFrom(value: number | bigint | Pointer): Pointer {
  if (typeof value === "number") {
    return value as unknown as Pointer;
  }
  if (typeof value === "bigint") {
    return Number(value) as unknown as Pointer;
  }
  return value;
}

function pointerToNumber(value: Pointer): number {
  return Number(value as unknown as bigint);
}

function decodeHeaders(ptrValue: number, length: number): Array<[string, string]> {
  if (ptrValue === 0 || length === 0) return [];
  const symbols = getServerSymbols();
  const results: Array<[string, string]> = [];
  const headerSize = requireHeaderStructSize();
  const buffer = new Uint8Array(headerSize * length);
  const rc = symbols.zig_h3_headers_copy(pointerFrom(ptrValue), length, ptr(buffer), length);
  if (rc < 0) {
    console.error("zig_h3_headers_copy failed", rc);
    return results;
  }
  const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
  for (let i = 0; i < length; i++) {
    const offset = i * headerSize;
    const namePtr = Number(view.getBigUint64(offset + 0, true));
    const nameLen = Number(view.getBigUint64(offset + 8, true));
    const valuePtr = Number(view.getBigUint64(offset + 16, true));
    const valueLen = Number(view.getBigUint64(offset + 24, true));
    const name = decodeUtf8(namePtr, nameLen);
    const value = decodeUtf8(valuePtr, valueLen);
    results.push([name, value]);
  }
  return results;
}

function toHeaders(pairs: Array<[string, string]>): Headers {
  const headers = new Headers();
  for (const [name, value] of pairs) {
    headers.append(name, value);
  }
  return headers;
}

function check(rc: number, ctx: string): void {
  if (rc !== 0) {
    throw new Error(`${ctx} failed with code ${rc}`);
  }
}

// ===== Context Wrapper Classes for Protocol Layers =====

/**
 * Context for raw QUIC datagrams (connection-scoped, server-level).
 * QUIC datagrams arrive before HTTP exchange and have no request context.
 */
export class QUICDatagramContext {
  readonly #symbols: ServerSymbols;
  readonly #connPtr: Pointer;
  readonly connectionId: Uint8Array;
  readonly connectionIdHex: string;

  constructor(symbols: ServerSymbols, connPtr: Pointer, connectionId: Uint8Array) {
    this.#symbols = symbols;
    this.#connPtr = connPtr;
    this.connectionId = connectionId;
    // Convert to hex for logging/comparison (binary-safe)
    this.connectionIdHex = Array.from(connectionId)
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
  }

  sendReply(data: Uint8Array): void {
    check(
      this.#symbols.zig_h3_server_send_quic_datagram(this.#connPtr, ptr(data), data.length),
      "QUICDatagramContext.sendReply",
    );
  }
}

/**
 * Context for HTTP/3 DATAGRAMs (request-associated with flow IDs).
 */
export class H3DatagramContext {
  readonly #symbols: ServerSymbols;
  readonly #responsePtr: Pointer;
  readonly streamId: bigint;
  readonly flowId: bigint;
  readonly request: Request;

  constructor(
    symbols: ServerSymbols,
    responsePtr: Pointer,
    streamId: bigint,
    flowId: bigint,
    request: Request,
  ) {
    this.#symbols = symbols;
    this.#responsePtr = responsePtr;
    this.streamId = streamId;
    this.flowId = flowId;
    this.request = request;
  }

  sendReply(data: Uint8Array): void {
    check(
      this.#symbols.zig_h3_response_send_h3_datagram(this.#responsePtr, ptr(data), data.length),
      "H3DatagramContext.sendReply",
    );
  }
}

/**
 * Context for WebTransport sessions (session-based with bidirectional streams).
 */
export class WTContext {
  readonly #symbols: ServerSymbols;
  readonly #sessionPtr: Pointer;
  readonly request: Request;
  readonly sessionId: bigint;

  constructor(symbols: ServerSymbols, sessionPtr: Pointer, request: Request, sessionId: bigint) {
    this.#symbols = symbols;
    this.#sessionPtr = sessionPtr;
    this.request = request;
    this.sessionId = sessionId;
  }

  sendDatagram(data: Uint8Array): void {
    check(
      this.#symbols.zig_h3_wt_send_datagram(this.#sessionPtr, ptr(data), data.length),
      "WTContext.sendDatagram",
    );
  }

  close(errorCode: number = 0, reason: string = ""): void {
    const reasonBuf = textEncoder.encode(reason);
    check(
      this.#symbols.zig_h3_wt_close(this.#sessionPtr, errorCode, ptr(reasonBuf), reasonBuf.length),
      "WTContext.close",
    );
  }
}

// ===== Route Definition Interface =====

export interface RouteDefinition {
  method: string;
  pattern: string;
  mode?: "buffered" | "streaming"; // Default: buffered
  fetch?: (req: Request, server: H3Server) => Response | Promise<Response>;
  h3Datagram?: (payload: Uint8Array, ctx: H3DatagramContext) => void;
  webtransport?: (ctx: WTContext) => void;
}

export interface H3ServeOptions {
  port?: number;
  hostname?: string;
  certPath?: string;
  keyPath?: string;
  enableDatagram?: boolean;
  enableWebTransport?: boolean;
  qlogDir?: string;
  logLevel?: number;

  // Route-first architecture: optional explicit routes
  routes?: RouteDefinition[];

  // Fallback handler (required if routes not provided, or for unmatched routes)
  fetch(request: Request, server: H3Server): Response | Promise<Response>;
  error?(error: unknown, server: H3Server): Response | Promise<Response>;

  // Server-level handler (not route-specific)
  quicDatagram?: (payload: Uint8Array, ctx: QUICDatagramContext) => void;
}

export class H3Server {
  #ptr: Pointer;
  readonly #buffers: Uint8Array[] = [];
  readonly #callbacks: JSCallback[] = [];
  readonly #options: H3ServeOptions;
  readonly #baseUrl: string;
  readonly #symbols: ServerSymbols;
  readonly port: number;
  readonly hostname: string;

  #running = false;
  #closed = false;

  constructor(options: H3ServeOptions) {
    if (typeof options.fetch !== "function") {
      throw new TypeError("H3Server requires a fetch handler");
    }
    this.#options = options;
    this.#symbols = getServerSymbols();
    this.port = options.port ?? 4433;
    this.hostname = options.hostname ?? "0.0.0.0";
    const scheme = "https";
    const authorityHost = options.hostname ?? "localhost";
    const authorityPort = this.port === 443 ? "" : `:${this.port}`;
    this.#baseUrl = `${scheme}://${authorityHost}${authorityPort}`;

    const configBuf = this.#buildConfigBuffer();
    const serverPtr = this.#symbols.zig_h3_server_new(ptr(configBuf));
    if (!serverPtr) {
      throw new Error("zig_h3_server_new returned null");
    }
    this.#ptr = serverPtr;

    this.#registerRoutes();
    this.start();
  }

  get running(): boolean {
    return this.#running;
  }

  #buildConfigBuffer(): ArrayBuffer {
    const cfg = new ArrayBuffer(48);
    const view = new DataView(cfg);

    const cert = makeCString(this.#options.certPath);
    const key = makeCString(this.#options.keyPath);
    const bindAddr = makeCString(this.hostname);
    const qlog = makeCString(this.#options.qlogDir);

    if (cert) this.#buffers.push(cert);
    if (key) this.#buffers.push(key);
    if (bindAddr) this.#buffers.push(bindAddr);
    if (qlog) this.#buffers.push(qlog);

    view.setBigUint64(0, BigInt(cert ? pointerToNumber(ptr(cert)) : 0), true);
    view.setBigUint64(8, BigInt(key ? pointerToNumber(ptr(key)) : 0), true);
    view.setBigUint64(16, BigInt(bindAddr ? pointerToNumber(ptr(bindAddr)) : 0), true);
    view.setUint16(24, this.port, true);
    view.setUint8(26, this.#options.enableDatagram ? 1 : 0);
    view.setUint8(27, this.#options.enableWebTransport ? 1 : 0);
    // padding for pointer alignment: bytes 28-31 remain zero.
    view.setBigUint64(32, BigInt(qlog ? pointerToNumber(ptr(qlog)) : 0), true);
    view.setUint8(40, this.#options.logLevel ?? 0);

    return cfg;
  }

  #registerRoutes(): void {
    if (this.#options.routes && this.#options.routes.length > 0) {
      // Register explicit routes first (higher precedence)
      for (const route of this.#options.routes) {
        this.#registerRoute(route);
      }
    }

    // Always register catch-all fallback for unmatched routes
    // Zig routing layer ensures specific patterns match before wildcards
    const patterns = ["/", "/*"];
    for (const method of DEFAULT_METHODS) {
      for (const pattern of patterns) {
        this.#registerRoute({
          method,
          pattern,
          mode: "buffered",
          fetch: this.#options.fetch,
        });
      }
    }
  }

  #registerRoute(route: RouteDefinition): void {
    const symbols = this.#symbols;
    const methodBuf = makeCString(route.method);
    const patternBuf = makeCString(route.pattern);
    if (!methodBuf || !patternBuf) {
      throw new Error(`Failed to allocate strings for route ${route.method} ${route.pattern}`);
    }
    this.#buffers.push(methodBuf, patternBuf);

    // Determine handler: use route-specific fetch or fallback to global fetch
    const fetchHandler = route.fetch || this.#options.fetch;

    const callback = new JSCallback(
      (_user, reqPtr, respPtr) => {
        if (!reqPtr || !respPtr) {
          return;
        }
        const requestPtr = reqPtr as Pointer;
        const responsePtr = respPtr as Pointer;
        try {
          check(symbols.zig_h3_response_defer_end(responsePtr), "zig_h3_response_defer_end");
        } catch (err) {
          console.error("Failed to defer response", err);
          return;
        }

        queueMicrotask(() => {
          this.#handleRequest(requestPtr, responsePtr, fetchHandler).catch((error) => {
            this.#handleError(error, responsePtr).catch((fallbackErr) => {
              console.error("Unable to emit error response", fallbackErr);
            });
          });
        });
      },
      {
        returns: FFIType.void,
        args: [FFIType.pointer, FFIType.pointer, FFIType.pointer],
        threadsafe: true,
      },
    );

    if (callback.ptr == null) {
      callback.close();
      throw new Error("JSCallback.ptr unavailable; ensure your Bun version exposes callback pointers");
    }

    this.#callbacks.push(callback);
    check(
      symbols.zig_h3_server_route(
        this.#ptr,
        ptr(methodBuf),
        ptr(patternBuf),
        callback.ptr,
        null,
        null,
        null,
      ),
      "zig_h3_server_route",
    );
  }

  async #handleRequest(
    requestPtr: Pointer,
    responsePtr: Pointer,
    fetchHandler: (req: Request, server: H3Server) => Response | Promise<Response>,
  ): Promise<void> {
    try {
      const request = this.#decodeRequest(requestPtr);
      if (process.env.H3_DEBUG_SERVER === "1") {
        console.debug(`[H3Server] handling ${request.method} ${request.url}`);
      }
      const result = await Promise.resolve(fetchHandler(request, this));
      await this.#sendResponse(result, responsePtr);
    } catch (error) {
      throw error;
    }
  }

  async #handleError(error: unknown, responsePtr: Pointer): Promise<void> {
    console.error("H3Server handler error", error);
    const fallback = this.#options.error
      ? await Promise.resolve(this.#options.error(error, this))
      : new Response("Internal Server Error", { status: 500 });
    await this.#sendResponse(fallback, responsePtr);
  }

  #decodeRequest(requestPtr: Pointer): Request {
    const structSize = 72; // sizeof(zig_h3_request) on 64-bit
    const buffer = new Uint8Array(toArrayBuffer(requestPtr, structSize));
    const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);

    const methodPtr = Number(view.getBigUint64(0, true));
    const methodLen = Number(view.getBigUint64(8, true));
    const pathPtr = Number(view.getBigUint64(16, true));
    const pathLen = Number(view.getBigUint64(24, true));
    const authorityPtr = Number(view.getBigUint64(32, true));
    const authorityLen = Number(view.getBigUint64(40, true));
    const headersPtr = Number(view.getBigUint64(48, true));
    const headersLen = Number(view.getBigUint64(56, true));

    const method = decodeUtf8(methodPtr, methodLen) || "GET";
    const path = decodeUtf8(pathPtr, pathLen) || "/";
    const authority = decodeUtf8(authorityPtr, authorityLen) || this.hostname;
    const headers = toHeaders(decodeHeaders(headersPtr, headersLen));

    const url = new URL(path, `${this.#baseUrl}`);
    if (!headers.has("host")) {
      headers.set("host", authority);
    }

    return new Request(url.toString(), {
      method,
      headers,
    });
  }

  async #sendResponse(response: Response, responsePtr: Pointer): Promise<void> {
    const symbols = this.#symbols;
    if (process.env.H3_DEBUG_SERVER === "1") {
      console.debug(`[H3Server] sending response status=${response.status}`);
    }
    check(symbols.zig_h3_response_status(responsePtr, response.status || 200), "zig_h3_response_status");

    for (const [key, value] of response.headers) {
      const nameBuf = textEncoder.encode(key);
      const valueBuf = textEncoder.encode(value);
      check(
        symbols.zig_h3_response_header(responsePtr, ptr(nameBuf), nameBuf.length, ptr(valueBuf), valueBuf.length),
        "zig_h3_response_header",
      );
    }

    const trailersCandidate = (response as unknown as { trailers?: Promise<Headers> | (() => Promise<Headers>) }).trailers;
    if (trailersCandidate) {
      let trailers: Headers | null = null;
      try {
        if (trailersCandidate instanceof Promise) {
          trailers = await trailersCandidate;
        } else if (typeof trailersCandidate === "function") {
          trailers = await trailersCandidate.call(response);
        }
      } catch {
        trailers = null;
      }

      if (trailers) {
        const trailerPairs: Array<[string, string]> = Array.from(trailers.entries());
        if (trailerPairs.length > 0) {
        const encoded = this.#encodeHeaders(trailerPairs);
        try {
          check(
            symbols.zig_h3_response_send_trailers(responsePtr, ptr(encoded.struct), trailerPairs.length),
            "zig_h3_response_send_trailers",
          );
          } finally {
            encoded.buffers.length = 0;
          }
        }
      }
    }

    if (!response.body) {
      const arrayBuffer = await response.arrayBuffer();
      const body = new Uint8Array(arrayBuffer);
    check(symbols.zig_h3_response_end(responsePtr, ptr(body), body.length), "zig_h3_response_end");
      return;
    }

    const reader = response.body.getReader();
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        if (!value) continue;
        const chunk = value instanceof Uint8Array ? value : new Uint8Array(value);
        if (chunk.length === 0) continue;
        check(symbols.zig_h3_response_write(responsePtr, ptr(chunk), chunk.length), "zig_h3_response_write");
      }
    } finally {
      reader.releaseLock();
    }

    check(symbols.zig_h3_response_end(responsePtr, null, 0), "zig_h3_response_end");
  }

  #encodeHeaders(pairs: Array<[string, string]>): { struct: Uint8Array; buffers: Uint8Array[] } {
    const recordSize = requireHeaderStructSize();
    const buffer = new Uint8Array(recordSize * pairs.length);
    const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
    const buffers: Uint8Array[] = [];
    for (let i = 0; i < pairs.length; i++) {
      const entry = pairs[i]!;
      const [name, value] = entry;
      const nameBuf = textEncoder.encode(name);
      const valueBuf = textEncoder.encode(value);
      buffers.push(nameBuf, valueBuf);
      const offset = i * recordSize;
      view.setBigUint64(offset + 0, BigInt(pointerToNumber(ptr(nameBuf))), true);
      view.setBigUint64(offset + 8, BigInt(nameBuf.length), true);
      view.setBigUint64(offset + 16, BigInt(pointerToNumber(ptr(valueBuf))), true);
      view.setBigUint64(offset + 24, BigInt(valueBuf.length), true);
    }
    return { struct: buffer, buffers };
  }

  start(): void {
    if (this.#running) return;
    check(this.#symbols.zig_h3_server_start(this.#ptr), "zig_h3_server_start");
    this.#running = true;
  }

  stop(): void {
    if (!this.#running) return;
    check(this.#symbols.zig_h3_server_stop(this.#ptr), "zig_h3_server_stop");
    this.#running = false;
  }

  close(): void {
    if (this.#closed) return;
    this.stop();
    check(this.#symbols.zig_h3_server_free(this.#ptr), "zig_h3_server_free");
    for (const cb of this.#callbacks) {
      cb.close();
    }
    this.#callbacks.length = 0;
    this.#buffers.length = 0;
    this.#closed = true;
  }
}

export function createH3Server(options: H3ServeOptions): H3Server {
  return new H3Server(options);
}
