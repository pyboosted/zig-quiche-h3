import { createHash } from "node:crypto";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { type Subprocess, spawn } from "bun";
import { existsSync } from "fs";

/**
 * Get the absolute path to the tests/tmp/e2e directory
 * This ensures all tests write to the same location regardless of where they're run from
 */
export function getTmpDir(): string {
    // Find the tests directory by looking for package.json
    let currentDir = resolve(import.meta.dir);
    while (currentDir !== "/") {
        if (existsSync(join(currentDir, "package.json"))) {
            return join(currentDir, "tmp", "e2e");
        }
        currentDir = dirname(currentDir);
    }
    // Fallback to tests/tmp/e2e from current location
    return resolve("tests", "tmp", "e2e");
}

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
    const tmpDir = getTmpDir();
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
    const tmpDir = getTmpDir();
    try {
        await rm(tmpDir, { recursive: true, force: true });
    } catch {
        // Ignore cleanup errors
    }
}

/**
 * Clean up old test files (older than specified minutes)
 */
export async function cleanupOldFiles(olderThanMinutes = 30): Promise<void> {
    console.log(
        `[E2E] cleanupOldFiles(${olderThanMinutes}) started at ${new Date().toISOString()}`,
    );
    const tmpDir = getTmpDir();
    console.log(`[E2E] tmpDir: ${tmpDir}`);
    const now = Date.now();
    const maxAge = olderThanMinutes * 60 * 1000;

    try {
        console.log(`[E2E] Importing fs/promises at ${new Date().toISOString()}`);
        const { readdir, stat, unlink } = await import("node:fs/promises");
        console.log(`[E2E] Reading directory at ${new Date().toISOString()}`);
        const files = await readdir(tmpDir);
        console.log(`[E2E] Found ${files.length} files in tmpDir at ${new Date().toISOString()}`);

        for (const file of files) {
            const filePath = join(tmpDir, file);
            try {
                const stats = await stat(filePath);
                if (now - stats.mtimeMs > maxAge) {
                    console.log(`[E2E] Deleting old file: ${file}`);
                    await unlink(filePath);
                }
            } catch (err) {
                console.log(`[E2E] Error processing file ${file}: ${err}`);
                // Ignore individual file errors
            }
        }
    } catch (err) {
        console.log(`[E2E] Error in cleanupOldFiles: ${err}`);
        // Ignore if directory doesn't exist
    }
    console.log(
        `[E2E] cleanupOldFiles(${olderThanMinutes}) completed at ${new Date().toISOString()}`,
    );
}

/**
 * Execute a function with a temporary directory, cleaning up after
 */
export async function withTempDir<T>(fn: (dir: string) => Promise<T>): Promise<T> {
    const baseDir = getTmpDir();
    const dir = join(baseDir, `test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
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
    intervalMs = 50, // Reduced from 100ms for faster polling
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

/**
 * Wait for a process to exit with a timeout
 * @param proc - The subprocess to wait for
 * @param timeoutMs - Maximum time to wait in milliseconds
 * @param killOnTimeout - Whether to kill the process on timeout (default: true)
 * @returns Promise that resolves when process exits or rejects on timeout
 */
export async function waitForProcessExit(
    proc: Subprocess,
    timeoutMs: number,
    killOnTimeout = true,
): Promise<void> {
    await Promise.race([
        proc.exited,
        new Promise<never>((_, reject) => {
            setTimeout(() => {
                if (killOnTimeout && !proc.killed) {
                    proc.kill();
                }
                reject(new Error(`Process did not exit within ${timeoutMs}ms`));
            }, timeoutMs);
        }),
    ]);
}

/**
 * Find the project root directory by looking for build.zig
 * Works from any subdirectory within the project
 */
export function getProjectRoot(): string {
    let current = resolve(process.cwd());
    const root = resolve("/");

    // Walk up the directory tree looking for build.zig
    while (current !== root) {
        if (existsSync(join(current, "build.zig"))) {
            return current;
        }
        const parent = dirname(current);
        if (parent === current) {
            // We've reached the root and can't go up further
            break;
        }
        current = parent;
    }

    throw new Error("Could not find project root (no build.zig found in parent directories)");
}

/**
 * Get the path to the zig-out directory
 * Works from any subdirectory within the project
 */
export function getZigOutDirectory(): string {
    const projectRoot = getProjectRoot();
    const zigOutPath = join(projectRoot, "zig-out");

    if (!existsSync(zigOutPath)) {
        throw new Error(`zig-out directory not found at ${zigOutPath}. Run 'zig build' first.`);
    }

    return zigOutPath;
}

/**
 * Server binary type enum
 */
export enum ServerBinaryType {
    Static = "quic-server",
    Dynamic = "quic-server-dyn",
}

/**
 * Get the full path to the server binary
 * Works from any subdirectory within the project
 * @param binaryType - The type of server binary to use (static or dynamic)
 */
export function getServerBinary(binaryType: ServerBinaryType = ServerBinaryType.Static): string {
    console.log(`[E2E] getServerBinary(${binaryType}) called at ${new Date().toISOString()}`);

    // Allow environment variable override
    const envBinary = process.env.H3_TEST_BINARY;
    const binaryName = envBinary || binaryType;

    const zigOut = getZigOutDirectory();
    const binaryPath = join(zigOut, "bin", binaryName);
    console.log(`[E2E] Looking for server binary (${binaryName}) at: ${binaryPath}`);

    if (!existsSync(binaryPath)) {
        console.log(`[E2E] Server binary NOT found at ${binaryPath}`);
        throw new Error(`Server binary not found at ${binaryPath}. Run 'zig build' first.`);
    }

    console.log(`[E2E] Server binary (${binaryName}) found at ${binaryPath}`);
    return binaryPath;
}

/**
 * Get the path to a certificate file
 * Works from any subdirectory within the project
 */
export function getCertPath(filename: string): string {
    const projectRoot = getProjectRoot();
    return join(projectRoot, "third_party", "quiche", "quiche", "examples", filename);
}

/**
 * Get the correct path to quiche directory based on current working directory.
 * Works from both project root and tests/ directory.
 */
export function getQuicheDirectory(): string {
    const projectRoot = getProjectRoot();
    const quichePath = join(projectRoot, "third_party", "quiche");

    if (!existsSync(quichePath)) {
        throw new Error(`Quiche directory not found at ${quichePath}`);
    }

    return quichePath;
}

/**
 * Check if a command is available in the system PATH
 */
export async function commandExists(command: string): Promise<boolean> {
    try {
        const proc = spawn({
            cmd: ["which", command],
            stdout: "pipe",
            stderr: "pipe",
        });
        await waitForProcessExit(proc, 5000);
        return proc.exitCode === 0;
    } catch {
        return false;
    }
}

/**
 * Check that all required dependencies are installed
 * Throws an error with helpful message if any are missing
 */
export async function checkDependencies(): Promise<void> {
    console.log(`[E2E] checkDependencies() started at ${new Date().toISOString()}`);
    const missing: string[] = [];

    // Check for required commands
    const dependencies = [
        { cmd: "zig", name: "Zig", install: "https://ziglang.org/download/" },
        { cmd: "cargo", name: "Cargo (Rust)", install: "https://rustup.rs/" },
    ];

    for (const dep of dependencies) {
        console.log(`[E2E] Checking for ${dep.cmd}...`);
        if (!(await commandExists(dep.cmd))) {
            console.log(`[E2E] Missing: ${dep.cmd}`);
            missing.push(`  - ${dep.name}: ${dep.install}`);
        } else {
            console.log(`[E2E] Found: ${dep.cmd}`);
        }
    }

    if (missing.length > 0) {
        throw new Error(
            `Missing required dependencies:\n${missing.join("\n")}\n\n` +
                "Please install the missing dependencies and try again.",
        );
    }
    console.log(`[E2E] checkDependencies() completed at ${new Date().toISOString()}`);
}
