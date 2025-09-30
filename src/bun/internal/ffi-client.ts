import { FFIType, JSCallback, ptr, toArrayBuffer } from "bun:ffi";
import type { Pointer } from "bun:ffi";
import { getSymbols, type ZigH3Symbols } from "./library";

const textDecoder = new TextDecoder();

let symbolsCache: ZigH3Symbols | null = null;
let fetchEventSize = 0;
let headerStructSize = 0;
let wtEventStructSize = 0;

const sleepSignal = new Int32Array(new SharedArrayBuffer(4));
function sleepMs(ms: number): void {
  Atomics.wait(sleepSignal, 0, 0, ms);
}

const CONNECT_RETRIES = 3;

function shouldRetryConnect(code: number): boolean {
  return code === -408 || code === -502 || code === -503;
}

function toPointerBigInt(value: number | bigint | null | undefined): bigint {
  if (value == null) return 0n;
  if (typeof value === "bigint") return value;
  if (typeof value === "number") return BigInt(value);
  throw new TypeError(`Unsupported pointer value type: ${typeof value}`);
}

function pointerFrom(value: number | bigint): Pointer {
  return value as unknown as Pointer;
}

function requireLib(): ZigH3Symbols {
  if (!symbolsCache) {
    symbolsCache = getSymbols();
    fetchEventSize = Number(symbolsCache.zig_h3_fetch_event_size());
    headerStructSize = Number(symbolsCache.zig_h3_header_size());
    wtEventStructSize = Number(symbolsCache.zig_h3_wt_event_size());
    if (process.env.DEBUG_FFI === "1") {
      console.debug("FFI sizes", {
        fetchEventSize,
        headerStructSize,
        wtEventStructSize,
      });
    }
  }
  return symbolsCache;
}

function toCString(str: string): Uint8Array {
  const bytes = new TextEncoder().encode(str);
  const buf = new Uint8Array(bytes.length + 1);
  buf.set(bytes, 0);
  buf[bytes.length] = 0;
  return buf;
}

function parseHeaders(
  symbols: ZigH3Symbols,
  ptrValue: bigint,
  length: number,
): Array<[string, string]> {
  if (ptrValue === 0n || length === 0) return [];
  const results: Array<[string, string]> = [];
  const basePtr = Number(ptrValue);
  const buffer = new Uint8Array(headerStructSize * length);
  const copyRc = symbols.zig_h3_headers_copy(
    pointerFrom(basePtr),
    length,
    ptr(buffer),
    length,
  );
  if (copyRc < 0) {
    console.error("zig_h3_headers_copy failed", copyRc);
    return results;
  }

  const headerView = new DataView(
    buffer.buffer,
    buffer.byteOffset,
    buffer.byteLength,
  );

  for (let i = 0; i < length; i++) {
    const offset = i * headerStructSize;
    const namePtr = Number(headerView.getBigUint64(offset + 0, true));
    const nameLen = Number(headerView.getBigUint64(offset + 8, true));
    const valuePtr = Number(headerView.getBigUint64(offset + 16, true));
    const valueLen = Number(headerView.getBigUint64(offset + 24, true));
    const nameBytes =
      namePtr === 0 || nameLen === 0
        ? new Uint8Array()
        : new Uint8Array(toArrayBuffer(pointerFrom(namePtr), nameLen));
    const valueBytes =
      valuePtr === 0 || valueLen === 0
        ? new Uint8Array()
        : new Uint8Array(toArrayBuffer(pointerFrom(valuePtr), valueLen));
    results.push([
      textDecoder.decode(nameBytes),
      textDecoder.decode(valueBytes),
    ]);
  }
  return results;
}

export interface FetchEventRecord {
  type: number;
  status: number;
  data?: Uint8Array;
  headers?: Array<[string, string]>;
  flowId: bigint;
  streamId: bigint;
}

export interface FetchResult {
  status: number;
  headers: Array<[string, string]>;
  trailers: Array<[string, string]>;
  body: Uint8Array;
  streamId: bigint;
  events: FetchEventRecord[];
}

export interface FetchOptions {
  method?: string;
  path: string;
  collectBody?: boolean;
  streamBody?: boolean;
  requestTimeoutMs?: number;
  onEvent?: (
    record: FetchEventRecord,
    sendDatagram: (payload: Uint8Array) => void,
  ) => void;
}

export interface ClientHandle {
  ptr: Pointer;
}

export interface WebTransportSessionHandle {
  ptr: Pointer | null;
  eventCallback: JSCallback;
}

export type WebTransportEvent =
  | {
      type: "connected";
      status: number;
      streamId: bigint;
    }
  | {
      type: "connectFailed";
      status: number;
      streamId: bigint;
    }
  | {
      type: "closed";
      streamId: bigint;
      errorCode: number;
      remote: boolean;
      reason: Uint8Array;
    }
  | {
      type: "datagram";
      streamId: bigint;
      datagramLength: number;
    };

export interface ClientConfigOptions {
  enableDatagram?: boolean;
  enableWebTransport?: boolean;
  enableDebugLogging?: boolean;
  verifyPeer?: boolean;
  idleTimeoutMs?: number;
  requestTimeoutMs?: number;
  connectTimeoutMs?: number;
}

export function createClient(config?: ClientConfigOptions): ClientHandle {
  const symbols = requireLib();
  const cfgBuffer = new ArrayBuffer(16);
  const view = new DataView(cfgBuffer);
  view.setUint8(0, config?.verifyPeer === false ? 0 : 1);
  view.setUint8(1, config?.enableDatagram ? 1 : 0);
  view.setUint8(2, config?.enableWebTransport ? 1 : 0);
  view.setUint8(3, config?.enableDebugLogging ? 1 : 0);
  view.setUint32(4, config?.idleTimeoutMs ?? 30_000, true);
  view.setUint32(8, config?.requestTimeoutMs ?? 30_000, true);
  view.setUint32(12, config?.connectTimeoutMs ?? 10_000, true);
  const clientPtr = symbols.zig_h3_client_new(ptr(cfgBuffer));
  if (clientPtr === null) {
    throw new Error("Failed to create client");
  }
  return { ptr: clientPtr };
}

export function freeClient(handle: ClientHandle): void {
  const symbols = requireLib();
  symbols.zig_h3_client_free(handle.ptr);
}

export function connectClient(
  handle: ClientHandle,
  host: string,
  port: number,
  sni?: string,
): void {
  const symbols = requireLib();
  const hostBuf = toCString(host);
  const sniBuf = sni ? toCString(sni) : null;

  for (let attempt = 0; attempt < CONNECT_RETRIES; attempt++) {
    const rc = symbols.zig_h3_client_connect(
      handle.ptr,
      ptr(hostBuf),
      port,
      sniBuf ? ptr(sniBuf) : null,
    );
    if (rc === 0) {
      return;
    }

    const hasRetry = attempt + 1 < CONNECT_RETRIES && shouldRetryConnect(rc);
    if (hasRetry) {
      symbols.zig_h3_client_run_once(handle.ptr);
      sleepMs(50 * (attempt + 1));
      continue;
    }

    throw new Error(`zig_h3_client_connect failed with code ${rc}`);
  }

  throw new Error("zig_h3_client_connect failed after retries");
}

export function fetchStreaming(
  handle: ClientHandle,
  options: FetchOptions,
): FetchResult {
  const symbols = requireLib();
  const methodBuf = options.method ? toCString(options.method) : null;
  const pathBuf = toCString(options.path);
  const collect = options.collectBody === false ? 0 : 1;
  const streamBody =
    options.streamBody != null
      ? options.streamBody
        ? 1
        : 0
      : collect === 0
        ? 1
        : 0;
  const timeout = options.requestTimeoutMs ?? 0;
  const events: FetchEventRecord[] = [];
  let finalBody = new Uint8Array();
  let finalStatus = 0;
  let finalHeaders: Array<[string, string]> = [];
  let finalTrailers: Array<[string, string]> = [];
  let streamIdBig = 0n;
  const eventBuffer = new Uint8Array(fetchEventSize);

  const eventCallback = new JSCallback(
    (_user, eventPtr) => {
      let eventAddr = 0;
      try {
        if (eventPtr == null) {
          console.error("ffi event callback received null event");
          return;
        }
        eventAddr = Number(eventPtr);
        const copyRc = symbols.zig_h3_fetch_event_copy(
          eventPtr,
          ptr(eventBuffer),
        );
        if (copyRc !== 0) {
          console.error("zig_h3_fetch_event_copy failed", copyRc);
          return;
        }
        const view = new DataView(
          eventBuffer.buffer,
          eventBuffer.byteOffset,
          fetchEventSize,
        );
        const type = view.getUint32(0, true);
        const status = view.getUint16(4, true);
        const headersPtr = view.getBigUint64(8, true);
        const headersLen = Number(view.getBigUint64(16, true));
        const dataPtr = view.getBigUint64(24, true);
        const dataLen = Number(view.getBigUint64(32, true));
        const flowId = view.getBigUint64(40, true);
        const streamId = view.getBigUint64(48, true);
        streamIdBig = streamId;

        const record: FetchEventRecord = {
          type,
          status,
          flowId,
          streamId,
        };

        if (headersPtr !== 0n && headersLen) {
          record.headers = parseHeaders(symbols, headersPtr, headersLen);
        }

        if (dataPtr !== 0n && dataLen) {
          const dataPtrNumber = Number(dataPtr);
          const buffer = new Uint8Array(dataLen);
          const copied = symbols.zig_h3_copy_bytes(
            pointerFrom(dataPtrNumber),
            dataLen,
            ptr(buffer),
          );
          if (copied > 0) {
            record.data = buffer.slice(0, copied);
          } else {
            record.data = new Uint8Array();
          }
        }

        events.push(record);

        if (options.onEvent) {
          options.onEvent(record, (payload: Uint8Array) => {
            symbols.zig_h3_client_send_h3_datagram(
              handle.ptr,
              Number(streamId),
              ptr(payload),
              payload.length,
            );
          });
        }
      } catch (err) {
        console.error(
          "ffi event callback error",
          err,
          "eventAddr=0x" + eventAddr.toString(16),
        );
      }
    },
    {
      returns: FFIType.void,
      args: [FFIType.pointer, FFIType.pointer],
      threadsafe: false,
    },
  );

  const responseCallback = new JSCallback(
    (
      _user,
      status,
      headersPtr,
      headersLen,
      bodyPtr,
      bodyLen,
      trailersPtr,
      trailersLen,
    ) => {
      try {
        finalStatus = status;
        const headersPtrBig = toPointerBigInt(headersPtr);
        finalHeaders = parseHeaders(symbols, headersPtrBig, Number(headersLen));
        const bodyPtrBig = toPointerBigInt(bodyPtr);
        if (bodyPtrBig !== 0n && bodyLen > 0) {
          finalBody = new Uint8Array(
            toArrayBuffer(pointerFrom(bodyPtrBig), Number(bodyLen)),
          );
        } else {
          finalBody = new Uint8Array();
        }
        const trailersPtrBig = toPointerBigInt(trailersPtr);
        finalTrailers = parseHeaders(
          symbols,
          trailersPtrBig,
          Number(trailersLen),
        );
      } catch (err) {
        console.error("ffi response callback error", err);
      }
    },
    {
      returns: FFIType.void,
      args: [
        FFIType.pointer,
        FFIType.u16,
        FFIType.pointer,
        "usize",
        FFIType.pointer,
        "usize",
        FFIType.pointer,
        "usize",
      ],
      threadsafe: false,
    },
  );

  const streamIdBuf = new BigUint64Array(1);
  const eventCallbackPtr = eventCallback.ptr;
  const responseCallbackPtr = responseCallback.ptr;

  const safeEventCallbackPtr = eventCallbackPtr && eventCallbackPtr !== 0 ? eventCallbackPtr : null;
  const safeResponseCallbackPtr =
    responseCallbackPtr && responseCallbackPtr !== 0 ? responseCallbackPtr : null;

  if (!safeEventCallbackPtr || !safeResponseCallbackPtr) {
    eventCallback.close();
    responseCallback.close();
    throw new Error(
      "JSCallback pointers are unavailable; ensure Bun runtime supports JSCallback.ptr",
    );
  }

  const eventPtr: Pointer = safeEventCallbackPtr as Pointer;
  const responsePtr: Pointer = safeResponseCallbackPtr as Pointer;

  const fetchSimple = symbols.zig_h3_client_fetch_simple as unknown as (
    client: Pointer,
    method: Pointer | null,
    path: Pointer,
    collect_body: number,
    stream_body: number,
    timeout_ms: number,
    event_cb: Pointer,
    event_user: Pointer | null,
    response_cb: Pointer,
    response_user: Pointer | null,
    stream_id_out: Pointer,
  ) => number;

  const rc = fetchSimple(
    handle.ptr,
    methodBuf ? ptr(methodBuf) : null,
    ptr(pathBuf),
    collect,
    streamBody,
    timeout,
    eventPtr,
    null,
    responsePtr,
    null,
    ptr(streamIdBuf),
  );

  // Bun currently keeps callbacks alive for the lifetime of the process.
  // Leaving the callbacks open during the request avoids race conditions if
  // the native library dispatches events as the call returns. Close them once
  // Bun exposes a safe synchronisation primitive.

  if (rc != 0) {
    throw new Error(`zig_h3_client_fetch_simple failed with code ${rc}`);
  }

  if (streamIdBig === 0n) {
    streamIdBig = streamIdBuf[0] ?? 0n;
  }

  return {
    status: finalStatus,
    headers: finalHeaders,
    trailers: finalTrailers,
    body: finalBody,
    streamId: streamIdBig,
    events,
  };
}

export function cancelFetch(
  handle: ClientHandle,
  streamId: bigint | number,
  errorCode = -503,
): void {
  const symbols = requireLib();
  const rc = symbols.zig_h3_client_cancel_fetch(
    handle.ptr,
    typeof streamId === "bigint" ? streamId : BigInt(streamId),
    errorCode,
  );
  if (rc !== 0) {
    throw new Error(`zig_h3_client_cancel_fetch failed with code ${rc}`);
  }
}

export function sendH3Datagram(
  handle: ClientHandle,
  streamId: bigint | number,
  payload: Uint8Array,
): void {
  const symbols = requireLib();
  const flowId = typeof streamId === "bigint" ? streamId : BigInt(streamId);
  symbols.zig_h3_client_send_h3_datagram(
    handle.ptr,
    flowId,
    ptr(payload),
    payload.length,
  );
}

export function sendQuicDatagram(
  handle: ClientHandle,
  payload: Uint8Array,
): void {
  const symbols = requireLib();
  symbols.zig_h3_client_send_datagram(handle.ptr, ptr(payload), payload.length);
}

function parseWebTransportEvent(
  view: DataView,
  copyBytes: (sourcePtr: number, length: number) => Uint8Array,
): WebTransportEvent {
  const eventType = view.getUint32(0, true);
  const status = view.getUint32(4, true);
  const errorCode = view.getInt32(8, true);
  const flags = view.getUint32(12, true);
  const streamIdBig = view.getBigUint64(16, true);
  const streamId = Number(streamIdBig);
  const reasonPtr = Number(view.getBigUint64(24, true));
  const reasonLen = Number(view.getBigUint64(32, true));
  const datagramPtr = Number(view.getBigUint64(40, true));
  const datagramLen = Number(view.getBigUint64(48, true));

  switch (eventType) {
    case 0:
      return { type: "connected", status, streamId: streamIdBig };
    case 1:
      return { type: "connectFailed", status, streamId: streamIdBig };
    case 2: {
      const remote = (flags & 0x1) !== 0;
      const reason =
        reasonPtr !== 0 && reasonLen > 0
          ? copyBytes(reasonPtr, reasonLen)
          : new Uint8Array();
      return {
        type: "closed",
        streamId: streamIdBig,
        errorCode,
        remote,
        reason,
      };
    }
    case 3:
      return {
        type: "datagram",
        streamId: streamIdBig,
        datagramLength: datagramLen,
      };
    default:
      throw new Error(`Unknown WebTransport event type: ${eventType}`);
  }
}

export function runClientOnce(handle: ClientHandle): void {
  const symbols = requireLib();
  symbols.zig_h3_client_run_once(handle.ptr);
}

export function pollClient(handle: ClientHandle): void {
  const symbols = requireLib();
  symbols.zig_h3_client_poll(handle.ptr);
}

export function openWebTransportSession(
  handle: ClientHandle,
  path: string,
  onEvent?: (event: WebTransportEvent) => void,
): WebTransportSessionHandle {
  const symbols = requireLib();
  const pathBuf = toCString(path);
  const copyBytes = (sourcePtr: number, length: number): Uint8Array => {
    const out = new Uint8Array(length);
    if (length > 0) {
  symbols.zig_h3_copy_bytes(pointerFrom(sourcePtr), length, ptr(out));
    }
    return out;
  };

  const eventBufferSize = wtEventStructSize > 0 ? wtEventStructSize : 56;
  const eventBuffer = new Uint8Array(eventBufferSize);

  const eventCallback = new JSCallback(
    (_user, sessionPtr, eventPtr) => {
      if (!onEvent || eventPtr === 0) return;
      const copyRc = symbols.zig_h3_wt_event_copy(eventPtr, ptr(eventBuffer));
      if (copyRc !== 0) {
        console.error("zig_h3_wt_event_copy failed", copyRc);
        return;
      }
      const view = new DataView(
        eventBuffer.buffer,
        eventBuffer.byteOffset,
        eventBuffer.byteLength,
      );
      const event = parseWebTransportEvent(view, copyBytes);
      if (sessionPtr !== 0) {
        onEvent(event);
      }
    },
    {
      returns: FFIType.void,
      args: [FFIType.pointer, FFIType.pointer, FFIType.pointer],
      threadsafe: false,
    },
  );

  const eventCallbackPtr = eventCallback.ptr;
  if (eventCallbackPtr == null) {
    eventCallback.close();
    throw new Error(
      "JSCallback pointers are unavailable; ensure Bun runtime supports JSCallback.ptr",
    );
  }

  const sessionPtr = symbols.zig_h3_client_open_webtransport(
    handle.ptr,
    ptr(pathBuf),
    pathBuf.length - 1,
    eventCallbackPtr,
    null,
  );

  if (sessionPtr === null) {
    eventCallback.close();
    throw new Error("zig_h3_client_open_webtransport returned null");
  }

  return { ptr: sessionPtr, eventCallback };
}

export function closeWebTransportSession(
  session: WebTransportSessionHandle,
  opts?: { errorCode?: number; reason?: Uint8Array },
): void {
  const symbols = requireLib();
  if (session.ptr === null) return;
  const reason = opts?.reason ?? new Uint8Array();
  const code = opts?.errorCode ?? 0;
  symbols.zig_h3_wt_session_close(
    session.ptr,
    code,
    ptr(reason),
    reason.length,
  );
}

export function sendWebTransportDatagram(
  session: WebTransportSessionHandle,
  payload: Uint8Array,
): void {
  const symbols = requireLib();
  if (session.ptr === null) {
    throw new Error("WebTransport session is closed");
  }
  if (payload.length === 0) return;
  const rc = symbols.zig_h3_wt_session_send_datagram(
    session.ptr,
    ptr(payload),
    payload.length,
  );
  if (rc !== 0) {
    throw new Error(`zig_h3_wt_session_send_datagram failed with code ${rc}`);
  }
}

export function receiveWebTransportDatagram(
  session: WebTransportSessionHandle,
): Uint8Array | null {
  const symbols = requireLib();
  if (session.ptr === null) {
    throw new Error("WebTransport session is closed");
  }
  const buffer = new BigUint64Array(2);
  const rc = symbols.zig_h3_wt_session_receive_datagram(
    session.ptr,
    ptr(buffer),
  );
  if (rc === -404) return null;
  if (rc !== 0) {
    throw new Error(
      `zig_h3_wt_session_receive_datagram failed with code ${rc}`,
    );
  }
  const dataPtr = Number(buffer[0]);
  const dataLen = Number(buffer[1]);
  if (dataLen === 0 || dataPtr === 0) {
    return new Uint8Array();
  }
  const out = new Uint8Array(dataLen);
  symbols.zig_h3_copy_bytes(pointerFrom(dataPtr), dataLen, ptr(out));
  symbols.zig_h3_wt_session_free_datagram(
    session.ptr,
    pointerFrom(dataPtr),
    dataLen,
  );
  return out;
}

export function isWebTransportEstablished(
  session: WebTransportSessionHandle,
): boolean {
  const symbols = requireLib();
  if (session.ptr === null) return false;
  return symbols.zig_h3_wt_session_is_established(session.ptr) === 1;
}

export function getWebTransportStreamId(
  session: WebTransportSessionHandle,
): bigint {
  const symbols = requireLib();
  if (session.ptr === null) {
    throw new Error("WebTransport session is closed");
  }
  return symbols.zig_h3_wt_session_stream_id(session.ptr);
}

export function freeWebTransportSession(
  session: WebTransportSessionHandle,
): void {
  const symbols = requireLib();
  if (session.ptr === null) return;
  session.eventCallback.close();
  symbols.zig_h3_wt_session_free(session.ptr);
  session.ptr = null;
}
