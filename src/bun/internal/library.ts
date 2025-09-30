import { dlopen, FFIType } from "bun:ffi";
import { existsSync } from "fs";
import { basename, join, resolve } from "path";

const platformLibMap: Record<NodeJS.Platform, string> = {
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
  haiku: "zig-out/lib/libzigquicheh3.so",
};

const PLATFORM = process.platform as keyof typeof platformLibMap;
const DEFAULT_REL_PATH = platformLibMap[PLATFORM] ?? platformLibMap.linux;

const PROJECT_ROOT = resolve(join(import.meta.dir, "../../.."));
function resolveLibraryPath(): string {
  const explicitPath = process.env.ZIG_H3_LIBPATH;
  if (explicitPath && existsSync(explicitPath)) {
    return explicitPath;
  }

  const explicitDir = process.env.ZIG_H3_LIBDIR;
  const candidate = explicitDir
    ? resolve(explicitDir, basename(DEFAULT_REL_PATH))
    : resolve(PROJECT_ROOT, DEFAULT_REL_PATH);

  return candidate;
}

function ensureBuilt(libPath: string): void {
  if (existsSync(libPath)) return;
  const projectRoot = PROJECT_ROOT;
  const build = Bun.spawnSync({
    cmd: ["zig", "build", "bun-ffi"],
    cwd: projectRoot,
    stdout: "inherit",
    stderr: "inherit",
  });
  if (build.exitCode !== 0 || !existsSync(libPath)) {
    throw new Error(
      `Failed to build bun-ffi artifacts (exit code ${build.exitCode}). Expected library at ${libPath}.`,
    );
  }
}

const CLIENT_SYMBOL_DEFINITIONS = {
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
    args: [FFIType.pointer, FFIType.pointer, FFIType.pointer, FFIType.pointer, FFIType.pointer],
  },
  zig_h3_client_cancel_fetch: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.u64, FFIType.i32],
  },
  zig_h3_client_send_h3_datagram: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.u64, FFIType.pointer, "usize"],
  },
  zig_h3_client_send_datagram: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.pointer, "usize"],
  },
  zig_h3_client_run_once: {
    returns: FFIType.i32,
    args: [FFIType.pointer],
  },
  zig_h3_client_poll: {
    returns: FFIType.i32,
    args: [FFIType.pointer],
  },
  zig_h3_client_open_webtransport: {
    returns: FFIType.pointer,
    args: [FFIType.pointer, FFIType.pointer, "usize", FFIType.pointer, FFIType.pointer],
  },
  zig_h3_wt_session_close: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.u32, FFIType.pointer, "usize"],
  },
  zig_h3_wt_session_send_datagram: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.pointer, "usize"],
  },
  zig_h3_wt_session_receive_datagram: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.pointer],
  },
  zig_h3_wt_session_free_datagram: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.pointer, "usize"],
  },
  zig_h3_wt_session_is_established: {
    returns: FFIType.i32,
    args: [FFIType.pointer],
  },
  zig_h3_wt_session_stream_id: {
    returns: FFIType.u64,
    args: [FFIType.pointer],
  },
  zig_h3_wt_session_free: {
    returns: FFIType.i32,
    args: [FFIType.pointer],
  },
  zig_h3_fetch_event_size: {
    returns: "usize",
    args: [],
  },
  zig_h3_header_size: {
    returns: "usize",
    args: [],
  },
  zig_h3_wt_event_size: {
    returns: "usize",
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
    args: [FFIType.pointer, "usize", "usize", FFIType.pointer],
  },
  zig_h3_headers_copy: {
    returns: FFIType.i32,
    args: [FFIType.pointer, "usize", FFIType.pointer, "usize"],
  },
  zig_h3_wt_event_copy: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.pointer],
  },
  zig_h3_copy_bytes: {
    returns: FFIType.i32,
    args: [FFIType.pointer, "usize", FFIType.pointer],
  },
  zig_h3_client_set_datagram_callback: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.pointer, FFIType.pointer],
  },
} as const;

const SERVER_SYMBOL_DEFINITIONS = {
  zig_h3_server_new: {
    returns: FFIType.pointer,
    args: [FFIType.pointer],
  },
  zig_h3_server_free: {
    returns: FFIType.i32,
    args: [FFIType.pointer],
  },
  zig_h3_server_route: {
    returns: FFIType.i32,
    args: [
      FFIType.pointer,
      FFIType.pointer,
      FFIType.pointer,
      FFIType.pointer,
      FFIType.pointer,
      FFIType.pointer,
      FFIType.pointer,
    ],
  },
  zig_h3_server_route_streaming: {
    returns: FFIType.i32,
    args: [
      FFIType.pointer,
      FFIType.pointer,
      FFIType.pointer,
      FFIType.pointer,
      FFIType.pointer,
      FFIType.pointer,
      FFIType.pointer,
      FFIType.pointer,
      FFIType.pointer,
    ],
  },
  zig_h3_server_set_stream_close_cb: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.pointer, FFIType.pointer],
  },
  zig_h3_server_set_connection_close_cb: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.pointer, FFIType.pointer],
  },
  zig_h3_server_set_quic_datagram_cb: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.pointer, FFIType.pointer],
  },
  zig_h3_server_send_quic_datagram: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.pointer, FFIType.pointer, "usize"],
  },
  zig_h3_server_start: {
    returns: FFIType.i32,
    args: [FFIType.pointer],
  },
  zig_h3_server_stop: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.u8],
  },
  zig_h3_server_set_log: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.pointer, FFIType.pointer],
  },
  zig_h3_server_stats: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.pointer],
  },
  zig_h3_response_status: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.u16],
  },
  zig_h3_response_header: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.pointer, "usize", FFIType.pointer, "usize"],
  },
  zig_h3_response_write: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.pointer, "usize"],
  },
  zig_h3_response_end: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.pointer, "usize"],
  },
  zig_h3_response_send_h3_datagram: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.pointer, "usize"],
  },
  zig_h3_response_send_trailers: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.pointer, "usize"],
  },
  zig_h3_response_defer_end: {
    returns: FFIType.i32,
    args: [FFIType.pointer],
  },
  zig_h3_response_set_auto_end: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.u8],
  },
  zig_h3_response_should_auto_end: {
    returns: FFIType.i32,
    args: [FFIType.pointer],
  },
  zig_h3_response_process_partial: {
    returns: FFIType.i32,
    args: [FFIType.pointer],
  },
  zig_h3_wt_accept: {
    returns: FFIType.i32,
    args: [FFIType.pointer],
  },
  zig_h3_wt_reject: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.u16],
  },
  zig_h3_wt_close: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.u32, FFIType.pointer, "usize"],
  },
  zig_h3_wt_send_datagram: {
    returns: FFIType.i32,
    args: [FFIType.pointer, FFIType.pointer, "usize"],
  },
  zig_h3_wt_release: {
    returns: FFIType.i32,
    args: [FFIType.pointer],
  },
} as const;

const FULL_SYMBOL_DEFINITIONS = {
  ...CLIENT_SYMBOL_DEFINITIONS,
  ...SERVER_SYMBOL_DEFINITIONS,
} as const;

type ClientDlopen = ReturnType<typeof dlopen<typeof CLIENT_SYMBOL_DEFINITIONS>>;
type FullDlopen = ReturnType<typeof dlopen<typeof FULL_SYMBOL_DEFINITIONS>>;

type LibraryHandle = { symbols: ClientDlopen["symbols"] & Partial<FullDlopen["symbols"]> };

let cachedSymbols: LibraryHandle | null = null;

function isMissingSymbolError(err: unknown): boolean {
  if (!(err instanceof Error)) return false;
  return /Symbol ".+" not found/.test(err.message);
}

export type ZigH3Symbols = LibraryHandle["symbols"];

export function loadLibrary(): LibraryHandle {
  if (cachedSymbols) return cachedSymbols;
  const libPath = resolveLibraryPath();
  ensureBuilt(libPath);
  try {
    const handle = dlopen<typeof FULL_SYMBOL_DEFINITIONS>(libPath, FULL_SYMBOL_DEFINITIONS);
    cachedSymbols = handle as LibraryHandle;
  } catch (err) {
    if (!isMissingSymbolError(err)) throw err;
    const fallback = dlopen<typeof CLIENT_SYMBOL_DEFINITIONS>(libPath, CLIENT_SYMBOL_DEFINITIONS);
    cachedSymbols = fallback as unknown as LibraryHandle;
  }
  return cachedSymbols;
}

export function getSymbols(): ZigH3Symbols {
  return loadLibrary().symbols;
}

export function hasServerSymbols(symbols: ZigH3Symbols): symbols is ZigH3Symbols &
  Required<Pick<typeof symbols, keyof typeof SERVER_SYMBOL_DEFINITIONS>> {
  for (const key of Object.keys(SERVER_SYMBOL_DEFINITIONS)) {
    if (!(key in symbols)) return false;
  }
  return true;
}

export type ServerSymbolKeys = keyof typeof SERVER_SYMBOL_DEFINITIONS;
export type ServerOnlySymbols = Required<Pick<ZigH3Symbols, ServerSymbolKeys>>;
