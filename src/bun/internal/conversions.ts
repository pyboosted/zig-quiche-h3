/**
 * Shared conversion utilities for FFI interop between Bun and zig-quiche-h3.
 *
 * This module provides type-safe helpers for marshalling data across the FFI boundary,
 * including string encoding, pointer conversions, and header serialization.
 */

import { ptr, toArrayBuffer, type Pointer } from "bun:ffi";
import type { ZigH3Symbols } from "./library";

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

/**
 * Convert a Bun pointer-like value to a Pointer type.
 * Handles number, bigint, and Pointer inputs uniformly.
 */
export function pointerFrom(value: number | bigint | Pointer): Pointer {
  if (typeof value === "number") {
    return value as unknown as Pointer;
  }
  if (typeof value === "bigint") {
    return Number(value) as unknown as Pointer;
  }
  return value;
}

/**
 * Convert a Bun Pointer to a number for arithmetic or FFI calls.
 */
export function pointerToNumber(value: Pointer): number {
  return Number(value as unknown as bigint);
}

/**
 * Create a null-terminated C string from a JavaScript string.
 * Returns null for undefined/empty input.
 *
 * @param value - JavaScript string to encode
 * @returns Uint8Array with null terminator, or null if input is empty
 */
export function makeCString(value: string | undefined): Uint8Array | null {
  if (!value) return null;
  const bytes = textEncoder.encode(value);
  const buf = new Uint8Array(bytes.length + 1);
  buf.set(bytes, 0);
  buf[bytes.length] = 0;
  return buf;
}

/**
 * Decode a UTF-8 string from a pointer and length.
 * Returns empty string for null/zero-length input.
 *
 * @param ptrValue - Memory address as number
 * @param len - String length in bytes
 * @returns Decoded UTF-8 string
 */
export function decodeUtf8(ptrValue: number, len: number): string {
  if (ptrValue === 0 || len === 0) return "";
  const data = new Uint8Array(toArrayBuffer(pointerFrom(ptrValue), len));
  return textDecoder.decode(data);
}

/**
 * Decode an array of HTTP headers from FFI memory.
 * Uses zig_h3_headers_copy to safely marshal header structs.
 *
 * @param symbols - FFI symbols (required for zig_h3_headers_copy and zig_h3_header_size)
 * @param ptrValue - Pointer to header array
 * @param length - Number of headers
 * @returns Array of [name, value] tuples
 */
export function decodeHeaders(
  symbols: ZigH3Symbols,
  ptrValue: number,
  length: number,
): Array<[string, string]> {
  if (ptrValue === 0 || length === 0) return [];

  const results: Array<[string, string]> = [];
  const headerSize = Number(symbols.zig_h3_header_size());
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

/**
 * Convert an array of [name, value] tuples to a Bun Headers object.
 * Appends duplicate header names rather than overwriting.
 *
 * @param pairs - Array of [name, value] tuples
 * @returns Bun Headers object
 */
export function toHeaders(pairs: Array<[string, string]>): Headers {
  const headers = new Headers();
  for (const [name, value] of pairs) {
    headers.append(name, value);
  }
  return headers;
}

/**
 * Encode HTTP headers for FFI transmission.
 * Allocates a struct array and returns both the struct and temporary buffers.
 * Caller must ensure buffers remain live during FFI call.
 *
 * @param symbols - FFI symbols (required for zig_h3_header_size)
 * @param pairs - Array of [name, value] tuples
 * @returns Object with struct buffer and temporary string buffers
 */
export function encodeHeaders(
  symbols: ZigH3Symbols,
  pairs: Array<[string, string]>,
): { struct: Uint8Array; buffers: Uint8Array[] } {
  const recordSize = Number(symbols.zig_h3_header_size());
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
 * Check FFI return code and throw descriptive error on failure.
 * Most FFI functions return 0 on success, negative on error.
 *
 * @param rc - FFI return code
 * @param ctx - Context string for error message (e.g., "zig_h3_server_start")
 * @throws Error if rc is non-zero
 */
export function check(rc: number, ctx: string): void {
  if (rc !== 0) {
    throw new Error(`${ctx} failed with code ${rc}`);
  }
}

/**
 * Validate that a string is a valid HTTP method.
 * Throws TypeError for invalid methods.
 *
 * @param method - HTTP method to validate
 * @throws TypeError if method is empty or contains invalid characters
 */
export function validateMethod(method: string): void {
  if (!method || method.length === 0) {
    throw new TypeError("HTTP method cannot be empty");
  }
  // RFC 9110: method = token (alphanumeric + !#$%&'*+-.^_`|~)
  if (!/^[A-Za-z0-9!#$%&'*+\-.^_`|~]+$/.test(method)) {
    throw new TypeError(
      `Invalid HTTP method "${method}": must be alphanumeric with allowed punctuation`,
    );
  }
}

/**
 * Validate that a route pattern is well-formed.
 * Throws TypeError for invalid patterns.
 *
 * @param pattern - Route pattern to validate (e.g., "/api/:id")
 * @throws TypeError if pattern doesn't start with "/" or contains invalid characters
 */
export function validateRoutePattern(pattern: string): void {
  if (!pattern || pattern.length === 0) {
    throw new TypeError("Route pattern cannot be empty");
  }
  if (!pattern.startsWith("/")) {
    throw new TypeError(`Route pattern "${pattern}" must start with "/"`);
  }
  // Basic validation: no whitespace, control chars
  if (/[\s\x00-\x1F\x7F]/.test(pattern)) {
    throw new TypeError(`Route pattern "${pattern}" contains invalid characters`);
  }
}

/**
 * Validate that a port number is in the valid range.
 * Throws RangeError for invalid ports.
 *
 * @param port - Port number to validate
 * @throws RangeError if port is not in range 1-65535
 */
export function validatePort(port: number): void {
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new RangeError(
      `Port must be an integer between 1 and 65535, got ${port}`,
    );
  }
}
