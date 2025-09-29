import { dlopen, FFIType, JSCallback, ptr, toArrayBuffer } from "bun:ffi";
import { existsSync } from "fs";
import { join } from "path";
import { getProjectRoot } from "./testUtils";

const textDecoder = new TextDecoder();

const libPathByPlatform: Record<NodeJS.Platform, string> = {
  darwin: "zig-out/lib/libzigquicheh3.dylib",
  linux: "zig-out/lib/libzigquicheh3.so",
  win32: "zig-out/bin/zigquicheh3.dll",
  aix: "zig-out/lib/libzigquicheh3.so",
  android: "zig-out/lib/libzigquicheh3.so",
  freebsd: "zig-out/lib/libzigquicheh3.so",
  openbsd: "zig-out/lib/libzigquicheh3.so",
  sunos: "zig-out/lib/libzigquicheh3.so",
  cygwin: "zig-out/bin/zigquicheh3.dll",
  netbsd: "zig-out/lib/libzigquicheh3.so",
};

const PLATFORM = process.platform as keyof typeof libPathByPlatform;

let libraryLoaded = false;
let ffiSymbols: ReturnType<typeof dlopen> | null = null;
let fetchEventSize = 0;
let headerStructSize = 0;

function toPointerBigInt(value: number | bigint | null | undefined): bigint {
  if (value == null) return 0n;
  if (typeof value === "bigint") return value;
  if (typeof value === "number") return BigInt(value);
  throw new TypeError(`Unsupported pointer value type: ${typeof value}`);
}

function ensureLibraryLoaded(): void {
  if (libraryLoaded) return;
  const projectRoot = getProjectRoot();
  const relPath = libPathByPlatform[PLATFORM] ?? libPathByPlatform.linux;
  const libFullPath = join(projectRoot, relPath);
  if (!existsSync(libFullPath)) {
    const build = Bun.spawnSync({
      cmd: ["zig", "build", "bun-ffi"],
      cwd: projectRoot,
      stdout: "inherit",
      stderr: "inherit",
    });
    if (build.exitCode !== 0 || !existsSync(libFullPath)) {
      throw new Error(
        `Failed to build bun-ffi target. Exit code ${build.exitCode}`,
      );
    }
  }

  ffiSymbols = dlopen(libFullPath, {
    zig_h3_client_new: {
      returns: FFIType.pointer,
      args: [FFIType.pointer],
    },
    zig_h3_client_free: {
      returns: FFIType.i32,
      args: [FFIType.pointer],
    },
    zig_h3_client_connect: {
      returns: FFIType.i32,
      args: [FFIType.pointer, FFIType.pointer, FFIType.u16, FFIType.pointer],
    },
    zig_h3_client_fetch_simple: {
      returns: FFIType.i32,
      args: [
        FFIType.pointer,
        FFIType.pointer,
        FFIType.pointer,
        FFIType.u8,
        FFIType.u8,
        FFIType.u32,
        FFIType.pointer,
        FFIType.pointer,
        FFIType.pointer,
        FFIType.pointer,
        FFIType.pointer,
      ],
    },
    zig_h3_client_fetch: {
      returns: FFIType.i32,
      args: [
        FFIType.pointer,
        FFIType.pointer,
        FFIType.pointer,
        FFIType.pointer,
        FFIType.pointer,
      ],
    },
    zig_h3_client_cancel_fetch: {
      returns: FFIType.i32,
      args: [FFIType.pointer, FFIType.u64, FFIType.i32],
    },
    zig_h3_client_send_h3_datagram: {
      returns: FFIType.i32,
      args: [FFIType.pointer, FFIType.u64, FFIType.pointer, FFIType.usize],
    },
    zig_h3_client_send_datagram: {
      returns: FFIType.i32,
      args: [FFIType.pointer, FFIType.pointer, FFIType.usize],
    },
    zig_h3_fetch_event_size: {
      returns: FFIType.usize,
      args: [],
    },
    zig_h3_header_size: {
      returns: FFIType.usize,
      args: [],
    },
    zig_h3_fetch_event_copy: {
      returns: FFIType.i32,
      args: [FFIType.pointer, FFIType.pointer],
    },
    zig_h3_header_copy: {
      returns: FFIType.i32,
      args: [FFIType.pointer, FFIType.pointer],
    },
    zig_h3_header_copy_at: {
      returns: FFIType.i32,
      args: [FFIType.pointer, FFIType.usize, FFIType.usize, FFIType.pointer],
    },
    zig_h3_headers_copy: {
      returns: FFIType.i32,
      args: [FFIType.pointer, FFIType.usize, FFIType.pointer, FFIType.usize],
    },
    zig_h3_copy_bytes: {
      returns: FFIType.i32,
      args: [FFIType.pointer, FFIType.usize, FFIType.pointer],
    },
    zig_h3_client_set_datagram_callback: {
      returns: FFIType.i32,
      args: [FFIType.pointer, FFIType.pointer, FFIType.pointer],
    },
  });

  fetchEventSize = Number(ffiSymbols.symbols.zig_h3_fetch_event_size());
  headerStructSize = Number(ffiSymbols.symbols.zig_h3_header_size());
  if (process.env.DEBUG_FFI === "1") {
    console.debug("FFI sizes", { fetchEventSize, headerStructSize });
  }
  libraryLoaded = true;
}

function requireLib() {
  ensureLibraryLoaded();
  if (!ffiSymbols) throw new Error("FFI library not loaded");
  return ffiSymbols.symbols;
}

function toCString(str: string): Uint8Array {
  const bytes = new TextEncoder().encode(str);
  const buf = new Uint8Array(bytes.length + 1);
  buf.set(bytes, 0);
  buf[bytes.length] = 0;
  return buf;
}

function parseHeaders(
  symbols: ReturnType<typeof requireLib>,
  ptrValue: bigint,
  length: number,
): Array<[string, string]> {
  if (ptrValue === 0n || length === 0) return [];
  const results: Array<[string, string]> = [];
  const basePtr = Number(ptrValue);
  const buffer = new Uint8Array(headerStructSize * length);
  const copyRc = symbols.zig_h3_headers_copy(
    basePtr,
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
        : new Uint8Array(toArrayBuffer(namePtr, nameLen));
    const valueBytes =
      valuePtr === 0 || valueLen === 0
        ? new Uint8Array()
        : new Uint8Array(toArrayBuffer(valuePtr, valueLen));
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
  ptr: number;
}

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
  const clientPtr = Number(symbols.zig_h3_client_new(ptr(cfgBuffer)));
  if (clientPtr === 0) {
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
  const rc = symbols.zig_h3_client_connect(
    handle.ptr,
    ptr(hostBuf),
    port,
    sniBuf ? ptr(sniBuf) : 0,
  );
  if (rc !== 0) {
    throw new Error(`zig_h3_client_connect failed with code ${rc}`);
  }
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
            dataPtrNumber,
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
            toArrayBuffer(bodyPtrBig, Number(bodyLen)),
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
        FFIType.usize,
        FFIType.pointer,
        FFIType.usize,
        FFIType.pointer,
        FFIType.usize,
      ],
      threadsafe: false,
    },
  );

  const streamIdBuf = new BigUint64Array(1);
  const eventCallbackPtr = eventCallback.ptr;
  const responseCallbackPtr = responseCallback.ptr;

  if (eventCallbackPtr == null || responseCallbackPtr == null) {
    eventCallback.close();
    responseCallback.close();
    throw new Error(
      "JSCallback pointers are unavailable; ensure Bun runtime supports JSCallback.ptr",
    );
  }

  const rc = symbols.zig_h3_client_fetch_simple(
    handle.ptr,
    methodBuf ? ptr(methodBuf) : null,
    ptr(pathBuf),
    collect,
    streamBody,
    timeout,
    eventCallbackPtr,
    0,
    responseCallbackPtr,
    0,
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
    streamIdBig = BigInt(streamIdBuf[0]);
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
    Number(streamId),
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
  symbols.zig_h3_client_send_h3_datagram(
    handle.ptr,
    Number(streamId),
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
