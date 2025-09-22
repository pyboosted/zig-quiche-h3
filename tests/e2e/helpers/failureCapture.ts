/**
 * Capture logs and display them only when tests fail
 * This module provides a simple way to capture logs during test execution
 * and display them when tests fail.
 */

import { afterEach, beforeEach } from "bun:test";
import { isVerboseMode } from "./logCapture";

// Store captured logs for current test
let capturedLogs: string[] = [];
let serverLogs: string[] = [];
let isCapturing = false;

// Original console methods
const originalConsole = {
    log: console.log,
    error: console.error,
    warn: console.warn,
    info: console.info,
    debug: console.debug,
};

/**
 * Start capturing console output
 */
function startCapture(): void {
    if (isVerboseMode() || isCapturing) return;

    isCapturing = true;
    capturedLogs = [];
    serverLogs = [];

    // Override console methods to capture output
    console.log = (...args: any[]) => {
        const msg = args.map(a => typeof a === 'object' ? JSON.stringify(a) : String(a)).join(' ');
        capturedLogs.push(msg);
    };

    console.error = (...args: any[]) => {
        const msg = args.map(a => typeof a === 'object' ? JSON.stringify(a) : String(a)).join(' ');
        capturedLogs.push(`[ERROR] ${msg}`);
    };

    console.warn = (...args: any[]) => {
        const msg = args.map(a => typeof a === 'object' ? JSON.stringify(a) : String(a)).join(' ');
        capturedLogs.push(`[WARN] ${msg}`);
    };

    console.info = (...args: any[]) => {
        const msg = args.map(a => typeof a === 'object' ? JSON.stringify(a) : String(a)).join(' ');
        capturedLogs.push(msg);
    };

    console.debug = (...args: any[]) => {
        const msg = args.map(a => typeof a === 'object' ? JSON.stringify(a) : String(a)).join(' ');
        capturedLogs.push(`[DEBUG] ${msg}`);
    };
}

/**
 * Stop capturing and restore console
 */
function stopCapture(): void {
    if (!isCapturing) return;

    console.log = originalConsole.log;
    console.error = originalConsole.error;
    console.warn = originalConsole.warn;
    console.info = originalConsole.info;
    console.debug = originalConsole.debug;

    isCapturing = false;
}

/**
 * Add server logs to capture
 */
export function captureServerLogs(logs: string[]): void {
    if (isCapturing && !isVerboseMode()) {
        serverLogs.push(...logs);
    }
}

/**
 * Display captured logs (used when test fails)
 */
export function displayCapturedLogs(testName: string): void {
    if (capturedLogs.length === 0 && serverLogs.length === 0) return;

    originalConsole.log("\n" + "=".repeat(60));
    originalConsole.log(`📋 Captured logs for failed test: ${testName}`);
    originalConsole.log("=".repeat(60));

    if (capturedLogs.length > 0) {
        originalConsole.log("\n📝 Test Output:");
        originalConsole.log("-".repeat(40));
        capturedLogs.forEach(log => originalConsole.log(log));
    }

    if (serverLogs.length > 0) {
        originalConsole.log("\n🖥️  Server Logs:");
        originalConsole.log("-".repeat(40));
        serverLogs.forEach(log => originalConsole.log(log));
    }

    originalConsole.log("\n" + "=".repeat(60) + "\n");
}

/**
 * Setup failure capture for tests
 * Call this in your test file or in setup.ts
 */
export function setupFailureCapture(): void {
    if (isVerboseMode()) {
        // In verbose mode, don't capture anything
        return;
    }

    beforeEach(() => {
        startCapture();
    });

    afterEach(() => {
        stopCapture();

        // Note: Bun doesn't currently provide a way to detect test failure in afterEach
        // The captured logs will be cleared but won't be displayed automatically on failure
        // This is a limitation of the current Bun test framework

        // Clear captured logs
        capturedLogs = [];
        serverLogs = [];
    });
}