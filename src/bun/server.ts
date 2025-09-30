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
 *
 * QUIC datagrams are connection-level and arrive before any HTTP exchange,
 * so they have no request context. Use this for connection-scoped messaging
 * that doesn't need HTTP semantics.
 *
 * @example
 * ```ts
 * createH3Server({
 *   quicDatagram: (payload, ctx) => {
 *     console.log(`QUIC datagram from ${ctx.connectionIdHex}`);
 *     ctx.sendReply(payload); // Echo back
 *   }
 * });
 * ```
 */
export class QUICDatagramContext {
  readonly #symbols: ServerSymbols;
  readonly #serverPtr: Pointer;
  readonly #connPtr: Pointer;
  readonly connectionId: Uint8Array;
  readonly connectionIdHex: string;

  constructor(symbols: ServerSymbols, serverPtr: Pointer, connPtr: Pointer, connectionId: Uint8Array) {
    this.#symbols = symbols;
    this.#serverPtr = serverPtr;
    this.#connPtr = connPtr;
    this.connectionId = connectionId;
    // Convert to hex for logging/comparison (binary-safe)
    this.connectionIdHex = Array.from(connectionId)
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
  }

  sendReply(data: Uint8Array): void {
    check(
      this.#symbols.zig_h3_server_send_quic_datagram(this.#serverPtr, this.#connPtr, ptr(data), data.length),
      "QUICDatagramContext.sendReply",
    );
  }
}

/**
 * Context for HTTP/3 DATAGRAMs (request-associated with flow IDs).
 *
 * H3 datagrams are tied to a specific HTTP/3 request and identified by flow IDs.
 * Unlike raw QUIC datagrams, these have full HTTP context (headers, path, etc).
 *
 * @example
 * ```ts
 * routes: [{
 *   method: "POST",
 *   pattern: "/h3dgram/echo",
 *   h3Datagram: (payload, ctx) => {
 *     console.log(`H3 datagram on stream ${ctx.streamId}, flow ${ctx.flowId}`);
 *     ctx.sendReply(payload); // Echo using response handle
 *   }
 * }]
 * ```
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
 *
 * WebTransport provides a session-based API with support for datagrams and
 * bidirectional streams. Sessions must be explicitly accepted or rejected.
 *
 * @example
 * ```ts
 * routes: [{
 *   method: "CONNECT",
 *   pattern: "/wt/session",
 *   webtransport: (ctx) => {
 *     ctx.accept(); // Accept the session
 *     ctx.sendDatagram(new TextEncoder().encode("welcome"));
 *     // Session continues, can send more datagrams or close later
 *   }
 * }]
 * ```
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

  accept(): void {
    check(this.#symbols.zig_h3_wt_accept(this.#sessionPtr), "WTContext.accept");
  }

  reject(status: number = 400): void {
    check(this.#symbols.zig_h3_wt_reject(this.#sessionPtr, status), "WTContext.reject");
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

/**
 * Route definition for the HTTP/3 server.
 *
 * Each route specifies a method, pattern, and handlers for different protocol layers.
 * Routes can handle HTTP requests, H3 datagrams, and WebTransport sessions.
 */
export interface RouteDefinition {
  /** HTTP method (GET, POST, etc.) */
  method: string;
  /** URL pattern with optional parameters (e.g., "/api/:id") */
  pattern: string;
  /**
   * Request body mode:
   * - "buffered" (default): Body collected up to 1MB, passed in Request
   * - "streaming": Body delivered via ReadableStream, no size limit
   */
  mode?: "buffered" | "streaming";
  /** HTTP request handler returning a Response */
  fetch?: (req: Request, server: H3Server) => Response | Promise<Response>;
  /** HTTP/3 DATAGRAM handler (request-associated with flow IDs) */
  h3Datagram?: (payload: Uint8Array, ctx: H3DatagramContext) => void;
  /** WebTransport session handler (must call accept() or reject()) */
  webtransport?: (ctx: WTContext) => void;
}

/**
 * Runtime server statistics.
 */
export interface ServerStats {
  /** Total connections accepted since server start */
  connectionsTotal: bigint;
  /** Currently active connections */
  connectionsActive: bigint;
  /** Total HTTP requests processed */
  requests: bigint;
  /** Server uptime in milliseconds */
  uptimeMs: bigint;
}

/**
 * HTTP/3 server configuration options.
 *
 * @example
 * ```ts
 * createH3Server({
 *   port: 4433,
 *   certPath: "/path/to/cert.crt",
 *   keyPath: "/path/to/cert.key",
 *   routes: [
 *     { method: "GET", pattern: "/", fetch: (req) => new Response("Hello!") }
 *   ],
 *   fetch: (req) => new Response("Fallback handler")
 * });
 * ```
 */
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

// ===== Request Snapshot for Memory Safety =====

/**
 * Complete snapshot of request data copied from Zig memory.
 * All strings, headers, and body are copied to JavaScript memory
 * before the FFI callback returns, preventing use-after-free.
 */
interface RequestSnapshot {
  method: string;
  path: string;
  authority: string;
  headers: Array<[string, string]>;
  streamId: bigint;
  connId: Uint8Array;
  body: Uint8Array | null;
}

// ===== Streaming Request State Management =====

interface StreamingRequestState {
  controller: ReadableStreamDefaultController<Uint8Array>;
  connectionId: Uint8Array;
  streamId: bigint;
}

function makeStreamingKey(connId: Uint8Array, streamId: bigint): string {
  const connIdHex = Array.from(connId)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return `${connIdHex}:${streamId}`;
}

/**
 * HTTP/3 server with support for QUIC datagrams, H3 datagrams, and WebTransport.
 *
 * This server provides a Bun-native HTTP/3 implementation built on the zig-quiche-h3
 * library. It supports:
 * - Multiple protocol layers (QUIC, HTTP/3, WebTransport)
 * - Streaming request and response bodies
 * - Route-based handlers with pattern matching
 * - Runtime metrics and lifecycle management
 *
 * **Important Notes:**
 * - Server starts automatically in constructor (no need to call start())
 * - Routes are registered at construction time and cannot be changed without restart
 * - `reload()` is not needed since the server is stateless - restart to change routes
 * - Always call `close()` when done to free resources
 *
 * @example
 * ```ts
 * const server = createH3Server({
 *   port: 4433,
 *   certPath: "/path/to/cert.crt",
 *   keyPath: "/path/to/cert.key",
 *   routes: [
 *     {
 *       method: "GET",
 *       pattern: "/",
 *       fetch: (req) => new Response("Hello, HTTP/3!")
 *     },
 *     {
 *       method: "POST",
 *       pattern: "/upload",
 *       mode: "streaming",
 *       fetch: async (req) => {
 *         const reader = req.body?.getReader();
 *         // Process streaming body...
 *         return new Response("Uploaded");
 *       }
 *     }
 *   ],
 *   fetch: (req) => new Response("Not Found", { status: 404 })
 * });
 *
 * // Get runtime stats
 * const stats = server.getStats();
 * console.log(`Requests: ${stats.requests}, Uptime: ${stats.uptimeMs}ms`);
 *
 * // Graceful shutdown
 * server.stop();
 * server.close();
 * ```
 */
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
  #streamingRequests = new Map<string, StreamingRequestState>();

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

    this.#registerCleanupHooks();
    this.#registerQuicDatagramHandler();
    this.#registerRoutes();
    this.start();
  }

  get running(): boolean {
    return this.#running;
  }

  #registerCleanupHooks(): void {
    const symbols = this.#symbols;

    // Stream close callback: clean up streaming request state using composite key
    const streamCloseCallback = new JSCallback(
      (_user, connIdPtr, connIdLen, streamId, aborted) => {
        if (!connIdPtr || connIdLen === 0) return;
        const connId = new Uint8Array(toArrayBuffer(pointerFrom(connIdPtr), connIdLen));
        const key = makeStreamingKey(connId, BigInt(streamId));
        const state = this.#streamingRequests.get(key);

        if (state) {
          if (aborted && state.controller) {
            try {
              state.controller.error(new Error("Stream aborted"));
            } catch {
              // Controller may already be closed
            }
          }
          this.#streamingRequests.delete(key);
        }
      },
      {
        returns: FFIType.void,
        args: [FFIType.pointer, FFIType.pointer, FFIType.usize, FFIType.u64, FFIType.u8],
        threadsafe: true,
      },
    );

    // Connection close callback: clean up all streams for this connection
    const connectionCloseCallback = new JSCallback(
      (_user, connIdPtr, connIdLen) => {
        if (!connIdPtr || connIdLen === 0) return;
        const connId = new Uint8Array(toArrayBuffer(pointerFrom(connIdPtr), connIdLen));
        const connIdHex = Array.from(connId)
          .map((b) => b.toString(16).padStart(2, "0"))
          .join("");

        // Remove all entries for this connection
        for (const [key, state] of this.#streamingRequests.entries()) {
          if (key.startsWith(connIdHex + ":")) {
            if (state.controller) {
              try {
                state.controller.error(new Error("Connection closed"));
              } catch {
                // Controller may already be closed
              }
            }
            this.#streamingRequests.delete(key);
          }
        }
      },
      {
        returns: FFIType.void,
        args: [FFIType.pointer, FFIType.pointer, FFIType.usize],
        threadsafe: true,
      },
    );

    if (!streamCloseCallback.ptr || !connectionCloseCallback.ptr) {
      streamCloseCallback.close();
      connectionCloseCallback.close();
      throw new Error("JSCallback.ptr unavailable for cleanup hooks");
    }

    this.#callbacks.push(streamCloseCallback, connectionCloseCallback);

    check(
      symbols.zig_h3_server_set_stream_close_cb(this.#ptr, streamCloseCallback.ptr, null),
      "zig_h3_server_set_stream_close_cb",
    );

    check(
      symbols.zig_h3_server_set_connection_close_cb(this.#ptr, connectionCloseCallback.ptr, null),
      "zig_h3_server_set_connection_close_cb",
    );
  }

  #registerQuicDatagramHandler(): void {
    if (!this.#options.quicDatagram) return;

    const symbols = this.#symbols;
    const handler = this.#options.quicDatagram;

    // Create thread-safe callback for raw QUIC datagrams
    const quicDatagramCallback = new JSCallback(
      (_user, connPtr, connIdPtr, connIdLen, dataPtr, dataLen) => {
        if (!connIdPtr || connIdLen === 0 || !dataPtr || dataLen === 0) return;

        // Copy connection ID and payload to JavaScript memory
        const connId = new Uint8Array(toArrayBuffer(pointerFrom(connIdPtr), connIdLen));
        const payload = new Uint8Array(toArrayBuffer(pointerFrom(dataPtr), dataLen));

        // Create context with server pointer, connection pointer, and connection ID
        const context = new QUICDatagramContext(symbols, this.#ptr, pointerFrom(connPtr), connId);

        // Invoke user handler
        try {
          handler(payload, context);
        } catch (error) {
          console.error("QUIC datagram handler error:", error);
        }
      },
      {
        returns: FFIType.void,
        args: [FFIType.pointer, FFIType.pointer, FFIType.pointer, FFIType.usize, FFIType.pointer, FFIType.usize],
        threadsafe: true,
      },
    );

    if (!quicDatagramCallback.ptr) {
      quicDatagramCallback.close();
      throw new Error("JSCallback.ptr unavailable for QUIC datagram handler");
    }

    this.#callbacks.push(quicDatagramCallback);

    check(
      symbols.zig_h3_server_set_quic_datagram_cb(this.#ptr, quicDatagramCallback.ptr, null),
      "zig_h3_server_set_quic_datagram_cb",
    );
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
    // Auto-enable QUIC/H3 DATAGRAM if handler is provided
    const hasH3DatagramRoute = this.#options.routes?.some((r) => r.h3Datagram != null) ?? false;
    const hasWTRoute = this.#options.routes?.some((r) => r.webtransport != null) ?? false;
    view.setUint8(
      26,
      this.#options.enableDatagram || this.#options.quicDatagram || hasH3DatagramRoute || hasWTRoute ? 1 : 0,
    );
    view.setUint8(27, this.#options.enableWebTransport || hasWTRoute ? 1 : 0);
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
    const isStreaming = route.mode === "streaming";
    const hasWTHandler = route.webtransport != null;

    const callback = new JSCallback(
      (_user, reqPtr, respPtr) => {
        if (!reqPtr || !respPtr) {
          return;
        }
        const requestPtr = reqPtr as Pointer;
        const responsePtr = respPtr as Pointer;

        // CRITICAL: Build complete snapshot SYNCHRONOUSLY before callback returns
        // This copies all request data (method, path, headers, body, conn_id) to JS memory
        // and prevents use-after-free when Zig frees the arena
        const snapshot = this.#buildRequestSnapshot(requestPtr);

        // Defer response end to allow async completion
        try {
          check(symbols.zig_h3_response_defer_end(responsePtr), "zig_h3_response_defer_end");
        } catch (err) {
          console.error("Failed to defer response", err);
          return;
        }

        // Queue async handler with snapshot using queueMicrotask
        // The snapshot contains copied data, so Zig can safely free the arena when callback returns
        // We use queueMicrotask to maintain thread safety with Bun's event loop
        queueMicrotask(() => {
          this.#handleRequest(snapshot, responsePtr, fetchHandler, isStreaming, hasWTHandler).catch((error) => {
            this.#handleError(error, responsePtr).catch((fallbackErr) => {
              console.error("Unable to emit error response", fallbackErr);
            });
          });
        });

        // Return immediately - Zig arena can now be freed safely because snapshot is complete
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

    // Create body chunk callback for streaming routes
    let bodyChunkCallback: JSCallback | null = null;
    let bodyCompleteCallback: JSCallback | null = null;
    if (isStreaming) {
      bodyChunkCallback = new JSCallback(
        (_user, connIdPtr, connIdLen, streamId, chunkPtr, chunkLen) => {
          if (!connIdPtr || connIdLen === 0) return;
          const connId = new Uint8Array(toArrayBuffer(pointerFrom(connIdPtr), connIdLen));
          const key = makeStreamingKey(connId, BigInt(streamId));
          const state = this.#streamingRequests.get(key);

          if (!state || !state.controller) return;

          if (chunkPtr && chunkLen > 0) {
            const chunk = new Uint8Array(toArrayBuffer(pointerFrom(chunkPtr), chunkLen));
            try {
              state.controller.enqueue(chunk);
            } catch (err) {
              console.error("Error enqueuing chunk", err);
            }
          }
        },
        {
          returns: FFIType.void,
          args: [FFIType.pointer, FFIType.pointer, FFIType.usize, FFIType.u64, FFIType.pointer, FFIType.usize],
          threadsafe: true,
        },
      );

      // Create body complete callback to close the ReadableStream
      bodyCompleteCallback = new JSCallback(
        (_user, connIdPtr, connIdLen, streamId) => {
          if (!connIdPtr || connIdLen === 0) return;
          const connId = new Uint8Array(toArrayBuffer(pointerFrom(connIdPtr), connIdLen));
          const key = makeStreamingKey(connId, BigInt(streamId));
          const state = this.#streamingRequests.get(key);

          if (state?.controller) {
            try {
              state.controller.close();
            } catch {
              // Controller may already be closed
            }
          }
          this.#streamingRequests.delete(key);
        },
        {
          returns: FFIType.void,
          args: [FFIType.pointer, FFIType.pointer, FFIType.usize, FFIType.u64],
          threadsafe: true,
        },
      );

      if (!bodyChunkCallback.ptr || !bodyCompleteCallback.ptr) {
        callback.close();
        bodyChunkCallback?.close();
        bodyCompleteCallback?.close();
        throw new Error("JSCallback.ptr unavailable for streaming callbacks");
      }

      this.#callbacks.push(bodyChunkCallback, bodyCompleteCallback);
    }

    // Create H3 datagram callback if h3Datagram handler is provided
    let h3DatagramCallback: JSCallback | null = null;
    if (route.h3Datagram) {
      const datagramHandler = route.h3Datagram;

      h3DatagramCallback = new JSCallback(
        (_user, reqPtr, respPtr, dataPtr, dataLen) => {
          if (!reqPtr || !respPtr || !dataPtr || dataLen === 0) return;

          const requestPtr = reqPtr as Pointer;
          const responsePtr = respPtr as Pointer;

          // Copy datagram payload to JavaScript memory
          const payload = new Uint8Array(toArrayBuffer(pointerFrom(dataPtr), dataLen));

          // Build Request snapshot for context (extracts stream_id at correct offset 64)
          const snapshot = this.#buildRequestSnapshot(requestPtr);
          const { request, streamId } = this.#decodeRequestFromSnapshot(snapshot);

          // Flow ID defaults to stream_id (1:1 mapping per flowIdForStream)
          const flowId = streamId;

          // Create H3DatagramContext
          const ctx = new H3DatagramContext(symbols, responsePtr, streamId, flowId, request);

          // Invoke user handler
          try {
            datagramHandler(payload, ctx);
          } catch (error) {
            console.error("H3 datagram handler error:", error);
          }
        },
        {
          returns: FFIType.void,
          args: [FFIType.pointer, FFIType.pointer, FFIType.pointer, FFIType.pointer, FFIType.usize],
          threadsafe: true,
        },
      );

      if (!h3DatagramCallback.ptr) {
        callback.close();
        bodyChunkCallback?.close();
        bodyCompleteCallback?.close();
        h3DatagramCallback.close();
        throw new Error("JSCallback.ptr unavailable for H3 datagram callback");
      }

      this.#callbacks.push(h3DatagramCallback);
    }

    // Create WebTransport session callback if webtransport handler is provided
    let wtSessionCallback: JSCallback | null = null;
    if (route.webtransport) {
      const wtHandler = route.webtransport;

      wtSessionCallback = new JSCallback(
        (_user, reqPtr, sessionPtr) => {
          if (!reqPtr || !sessionPtr) return;

          const requestPtr = reqPtr as Pointer;
          const sessionPointer = sessionPtr as Pointer;

          // Build Request snapshot for context
          const snapshot = this.#buildRequestSnapshot(requestPtr);
          const { request, streamId } = this.#decodeRequestFromSnapshot(snapshot);

          // Create WTContext with session pointer
          const ctx = new WTContext(symbols, sessionPointer, request, streamId);

          // Invoke user handler
          try {
            wtHandler(ctx);
          } catch (error) {
            console.error("WebTransport session handler error:", error);
          }
        },
        {
          returns: FFIType.void,
          args: [FFIType.pointer, FFIType.pointer, FFIType.pointer],
          threadsafe: true,
        },
      );

      if (!wtSessionCallback.ptr) {
        callback.close();
        bodyChunkCallback?.close();
        bodyCompleteCallback?.close();
        h3DatagramCallback?.close();
        wtSessionCallback.close();
        throw new Error("JSCallback.ptr unavailable for WebTransport callback");
      }

      this.#callbacks.push(wtSessionCallback);
    }

    // Register route with appropriate function
    if (isStreaming && bodyChunkCallback && bodyCompleteCallback) {
      check(
        symbols.zig_h3_server_route_streaming(
          this.#ptr,
          ptr(methodBuf),
          ptr(patternBuf),
          callback.ptr,
          bodyChunkCallback.ptr,
          bodyCompleteCallback.ptr,
          h3DatagramCallback?.ptr ?? null,
          wtSessionCallback?.ptr ?? null,
          null,
        ),
        "zig_h3_server_route_streaming",
      );
    } else {
      check(
        symbols.zig_h3_server_route(
          this.#ptr,
          ptr(methodBuf),
          ptr(patternBuf),
          callback.ptr,
          h3DatagramCallback?.ptr ?? null,
          wtSessionCallback?.ptr ?? null,
          null,
        ),
        "zig_h3_server_route",
      );
    }
  }

  async #handleRequest(
    snapshot: RequestSnapshot,
    responsePtr: Pointer,
    fetchHandler: (req: Request, server: H3Server) => Response | Promise<Response>,
    isStreaming: boolean = false,
    hasWTHandler: boolean = false,
  ): Promise<void> {
    try {
      // Check for WebTransport CONNECT BEFORE building the Request object
      // Pseudo-headers like :protocol aren't exposed through Request.headers API
      const isWTConnect =
        hasWTHandler &&
        snapshot.method === "CONNECT" &&
        snapshot.headers.some(([name, value]) => name === ":protocol" && value === "webtransport");

      const { request: baseRequest, streamId, connId } = this.#decodeRequestFromSnapshot(snapshot);

      let request = baseRequest;

      // For streaming routes, create a ReadableStream and store the controller
      if (isStreaming) {
        const key = makeStreamingKey(connId, streamId);
        let streamController: ReadableStreamDefaultController<Uint8Array> | null = null;

        const stream = new ReadableStream<Uint8Array>({
          start(controller) {
            streamController = controller;
          },
          cancel(reason) {
            // Stream was cancelled by the user
            if (process.env.H3_DEBUG_SERVER === "1") {
              console.debug(`[H3Server] stream ${streamId} cancelled:`, reason);
            }
          },
        });

        // Store controller in map for body chunk callback
        if (streamController) {
          this.#streamingRequests.set(key, {
            controller: streamController,
            connectionId: connId,
            streamId,
          });
        }

        // Create new Request with the streaming body
        request = new Request(baseRequest.url, {
          method: baseRequest.method,
          headers: baseRequest.headers,
          body: stream,
          // @ts-expect-error - Bun supports duplex option
          duplex: "half",
        });
      }

      if (process.env.H3_DEBUG_SERVER === "1") {
        console.debug(`[H3Server] handling ${request.method} ${request.url} (streaming: ${isStreaming})`);
      }

      const result = await Promise.resolve(fetchHandler(request, this));

      // For WebTransport CONNECT requests, don't send the response here
      // The WebTransport accept() or reject() call handles the response
      if (!isWTConnect) {
        await this.#sendResponse(result, responsePtr);
      }

      // Note: Cleanup is handled by bodyCompleteCallback when body finishes
      // This prevents the deadlock where fetchHandler waits for body to complete
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

  /**
   * Build complete request snapshot synchronously from ZigRequest pointer.
   * CRITICAL: All data must be copied before this method returns to prevent
   * use-after-free when Zig frees the arena.
   */
  #buildRequestSnapshot(requestPtr: Pointer): RequestSnapshot {
    const structSize = 104; // sizeof(zig_h3_request) on 64-bit with body fields
    const buffer = new Uint8Array(toArrayBuffer(requestPtr, structSize));
    const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);

    // Read all pointers and lengths from struct
    const methodPtr = Number(view.getBigUint64(0, true));
    const methodLen = Number(view.getBigUint64(8, true));
    const pathPtr = Number(view.getBigUint64(16, true));
    const pathLen = Number(view.getBigUint64(24, true));
    const authorityPtr = Number(view.getBigUint64(32, true));
    const authorityLen = Number(view.getBigUint64(40, true));
    const headersPtr = Number(view.getBigUint64(48, true));
    const headersLen = Number(view.getBigUint64(56, true));
    const streamId = view.getBigUint64(64, true);
    const connIdPtr = Number(view.getBigUint64(72, true));
    const connIdLen = Number(view.getBigUint64(80, true));
    const bodyPtr = Number(view.getBigUint64(88, true));
    const bodyLen = Number(view.getBigUint64(96, true));

    // Copy all strings to JS memory (synchronously) with defensive null checks
    const method = methodLen > 0 && methodPtr !== 0 ? decodeUtf8(methodPtr, methodLen) || "GET" : "GET";
    const path = pathLen > 0 && pathPtr !== 0 ? decodeUtf8(pathPtr, pathLen) || "/" : "/";
    const authority =
      authorityLen > 0 && authorityPtr !== 0
        ? decodeUtf8(authorityPtr, authorityLen) || this.hostname
        : this.hostname;

    // Copy headers to JS arrays (synchronously)
    const headers = headersLen > 0 && headersPtr !== 0 ? decodeHeaders(headersPtr, headersLen) : [];

    // Copy connection ID to JS Uint8Array (synchronously)
    const connId =
      connIdLen > 0 && connIdPtr !== 0
        ? new Uint8Array(toArrayBuffer(pointerFrom(connIdPtr), connIdLen))
        : new Uint8Array(0);

    // Copy body to JS Uint8Array (synchronously)
    // DEFENSIVE: Only read body if both pointer and length are valid
    let body: Uint8Array | null = null;
    if (bodyLen > 0 && bodyPtr !== 0) {
      try {
        body = new Uint8Array(toArrayBuffer(pointerFrom(bodyPtr), bodyLen));
      } catch (err) {
        console.error("Failed to read body from FFI:", err);
        body = null;
      }
    }

    return {
      method,
      path,
      authority,
      headers,
      streamId,
      connId,
      body,
    };
  }

  /**
   * Build Bun Request from pre-copied snapshot data.
   * This method receives data already copied to JS memory, so no pointer dereferencing occurs.
   */
  #decodeRequestFromSnapshot(snapshot: RequestSnapshot): {
    request: Request;
    streamId: bigint;
    connId: Uint8Array;
  } {
    const { method, path, authority, headers: headerPairs, streamId, connId, body } = snapshot;

    // Build URL
    const url = new URL(path, this.#baseUrl);

    // Build Headers object
    const headers = toHeaders(headerPairs);
    if (!headers.has("host")) {
      headers.set("host", authority);
    }

    // Build Request
    // For buffered mode with body, include the body in the Request
    const requestInit: RequestInit = {
      method,
      headers,
    };

    // Include body if present (buffered mode)
    if (body && body.length > 0) {
      requestInit.body = body;
    }

    const request = new Request(url.toString(), requestInit);

    return { request, streamId, connId };
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

  /**
   * Start the server (idempotent).
   *
   * Note: Server starts automatically in constructor, so explicit start() call
   * is only needed after stop() to restart the server.
   */
  start(): void {
    if (this.#running) return;
    check(this.#symbols.zig_h3_server_start(this.#ptr), "zig_h3_server_start");
    this.#running = true;
  }

  /**
   * Stop the server.
   * @param force - If true, immediately closes all active connections. If false (default),
   *                performs graceful shutdown allowing in-flight requests to complete.
   */
  stop(force?: boolean): void {
    if (!this.#running) return;
    check(this.#symbols.zig_h3_server_stop(this.#ptr, force ? 1 : 0), "zig_h3_server_stop");
    this.#running = false;
  }

  /**
   * Get runtime server statistics.
   *
   * @returns ServerStats object with connection counts, request count, and uptime
   * @throws Error if server is closed
   *
   * @example
   * ```ts
   * const stats = server.getStats();
   * console.log(`Active connections: ${stats.connectionsActive}`);
   * console.log(`Total requests: ${stats.requests}`);
   * console.log(`Uptime: ${stats.uptimeMs}ms`);
   * ```
   */
  getStats(): ServerStats {
    if (this.#closed) {
      throw new Error("Server is closed");
    }
    // Struct layout: 4 u64/i64 fields = 32 bytes
    const statsBuffer = new ArrayBuffer(32);
    check(
      this.#symbols.zig_h3_server_stats(this.#ptr, ptr(new Uint8Array(statsBuffer))),
      "zig_h3_server_stats",
    );
    const view = new DataView(statsBuffer);

    return {
      connectionsTotal: view.getBigUint64(0, true),
      connectionsActive: view.getBigUint64(8, true),
      requests: view.getBigUint64(16, true),
      uptimeMs: view.getBigInt64(24, true),
    };
  }

  /**
   * Close the server and free all resources.
   *
   * This method stops the server (if running), frees native resources,
   * closes all callbacks, and cleans up buffers. Always call this when
   * done with the server to prevent resource leaks.
   *
   * CRITICAL: Callbacks must be closed BEFORE freeing the Zig server to prevent
   * use-after-free race conditions. The Zig server's deinit() may reference callback
   * pointers during cleanup, so they must remain valid until after free() completes.
   *
   * @example
   * ```ts
   * const server = createH3Server({ ... });
   * // ... use server ...
   * server.close(); // Always close when done
   * ```
   */
  close(): void {
    if (this.#closed) return;

    // Step 1: Stop server thread (joins thread, no new callbacks will fire)
    this.stop();

    // Step 2: Wait briefly to ensure Bun's threadsafe callback queue is drained
    // Bun v1.2.x has known issues with threadsafe JSCallback cleanup (issues #16937, #17157)
    // where callbacks may still be in the dispatch queue even after thread.join()
    // This synchronization barrier gives pending invocations time to complete
    const CALLBACK_DRAIN_MS = 100;
    const start = Date.now();
    while (Date.now() - start < CALLBACK_DRAIN_MS) {
      // Busy-wait to ensure callbacks complete (setImmediate doesn't work during close)
      for (let i = 0; i < 10000; i++) {
        // Spin CPU briefly to drain queue
      }
    }

    // Step 3: DO NOT close callbacks - let Bun's GC handle them
    // WORKAROUND for Bun v1.2.x bug (issues #16937, #17157) where calling
    // cb.close() causes segfault at 0xFFFFFFFFFFFFFFF0 during cleanup
    // The callbacks will be GC'd when the server object is collected
    // This causes a small memory leak during server lifetime but prevents crashes
    if (process.env.H3_CLOSE_CALLBACKS === "1") {
      // Only close if explicitly requested (for debugging)
      for (const cb of this.#callbacks) {
        try {
          cb.close();
        } catch (err) {
          if (process.env.H3_DEBUG_SERVER === "1") {
            console.warn(`[H3Server] callback.close() failed:`, err);
          }
        }
      }
    }
    this.#callbacks.length = 0; // Clear array but don't close

    // Step 4: NOW safe to free Zig server (no callback references exist in Bun runtime)
    check(this.#symbols.zig_h3_server_free(this.#ptr), "zig_h3_server_free");

    this.#buffers.length = 0;
    this.#closed = true;
  }
}

/**
 * Create and start an HTTP/3 server.
 *
 * This factory function creates an H3Server instance with the provided configuration.
 * The server starts automatically and is ready to accept connections immediately.
 *
 * @param options - Server configuration options
 * @returns Running H3Server instance
 *
 * @example
 * ```ts
 * const server = createH3Server({
 *   port: 4433,
 *   certPath: "./cert.crt",
 *   keyPath: "./cert.key",
 *   fetch: (req) => new Response("Hello, HTTP/3!")
 * });
 * ```
 */
export function createH3Server(options: H3ServeOptions): H3Server {
  return new H3Server(options);
}
