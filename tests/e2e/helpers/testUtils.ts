import { createHash } from "node:crypto";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

/**
 * Information about a generated test file
 */
export interface TestFile {
  path: string;
  size: number;
  sha256: string;
}

/**
 * Create a test file with specified size and optional pattern
 */
export async function mkfile(size: number, pattern?: Uint8Array): Promise<TestFile> {
  // Ensure tmp directory exists
  const tmpDir = "./tmp/e2e";
  await mkdir(tmpDir, { recursive: true });

  // Generate unique filename
  const filename = `test-${Date.now()}-${Math.random().toString(36).slice(2)}.bin`;
  const path = join(tmpDir, filename);

  // Generate content
  const buffer = new Uint8Array(size);
  if (pattern) {
    for (let i = 0; i < size; i++) {
      buffer[i] = pattern[i % pattern.length]!;
    }
  } else {
    // Default pattern: repeating bytes 0-255
    for (let i = 0; i < size; i++) {
      buffer[i] = i & 0xff;
    }
  }

  // Write file
  await writeFile(path, buffer);

  // Calculate SHA-256
  const hash = createHash("sha256");
  hash.update(buffer);
  const sha256 = hash.digest("hex");

  return { path, size, sha256 };
}

/**
 * Generate a random port in the specified range
 */
export function randPort(base = 44330, span = 2000): number {
  return base + Math.floor(Math.random() * span);
}

/**
 * Clean up all temporary files and directories
 */
export async function cleanupAll(): Promise<void> {
  try {
    await rm("./tmp", { recursive: true, force: true });
  } catch {
    // Ignore cleanup errors
  }
}

/**
 * Execute a function with a temporary directory, cleaning up after
 */
export async function withTempDir<T>(fn: (dir: string) => Promise<T>): Promise<T> {
  const dir = `./tmp/e2e/test-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  await mkdir(dir, { recursive: true });

  try {
    return await fn(dir);
  } finally {
    try {
      await rm(dir, { recursive: true, force: true });
    } catch {
      // Ignore cleanup errors
    }
  }
}

/**
 * Type-safe JSON schema validation
 */
export function expectJson<T>(actual: unknown, expected: T): asserts actual is T {
  if (typeof actual !== typeof expected) {
    throw new Error(`Type mismatch: expected ${typeof expected}, got ${typeof actual}`);
  }

  if (Array.isArray(expected) && !Array.isArray(actual)) {
    throw new Error("Expected array");
  }

  if (expected !== null && typeof expected === "object" && !Array.isArray(expected)) {
    if (actual === null || typeof actual !== "object" || Array.isArray(actual)) {
      throw new Error("Expected object");
    }

    // Check required properties exist
    for (const key in expected) {
      if (!(key in actual)) {
        throw new Error(`Missing property: ${key}`);
      }
    }
  }
}

/**
 * Parse content-length header safely
 */
export function parseContentLength(headers: Map<string, string>): number | null {
  const cl = headers.get("content-length");
  if (!cl) return null;

  const parsed = Number.parseInt(cl, 10);
  return Number.isNaN(parsed) ? null : parsed;
}

/**
 * Convert hex string to bytes for comparison
 */
export function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = Number.parseInt(hex.slice(i, i + 2), 16);
  }
  return bytes;
}

/**
 * Wait for a condition with timeout
 */
export async function waitFor(
  condition: () => boolean | Promise<boolean>,
  timeoutMs = 5000,
  intervalMs = 100,
): Promise<void> {
  const start = Date.now();

  while (Date.now() - start < timeoutMs) {
    if (await condition()) {
      return;
    }
    await Bun.sleep(intervalMs);
  }

  throw new Error(`Condition not met within ${timeoutMs}ms`);
}
