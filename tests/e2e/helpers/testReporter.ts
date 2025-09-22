/**
 * Test reporter wrapper that captures logs and only shows them on failure
 */

import { afterEach, beforeEach } from "bun:test";
import { getLogCapture, isVerboseMode } from "./logCapture";

interface TestContext {
    testName: string;
    suiteName: string;
    serverLogs: string[];
    clientLogs: string[];
}

// Store test context for current test
let currentTestContext: TestContext | null = null;

// Store server logs per test
const testServerLogs = new Map<string, string[]>();

// Store client logs per test
const testClientLogs = new Map<string, string[]>();

/**
 * Initialize the test reporter for a test suite
 * @param suiteName The name of the test suite
 */
export function initTestReporter(suiteName: string): void {
    const logCapture = getLogCapture();
    const verboseMode = isVerboseMode();

    beforeEach(() => {
        // Get test name - will be populated during test run
        const testName = "current-test";

        // Create test context
        currentTestContext = {
            testName,
            suiteName,
            serverLogs: [],
            clientLogs: [],
        };

        // Start capturing logs (unless in verbose mode)
        if (!verboseMode) {
            logCapture.start();
        }
    });

    afterEach(() => {
        const testName = "current-test";
        const testKey = `${suiteName}::${testName}`;

        // For now, we'll just clear logs after each test
        // since Bun doesn't provide easy access to test results in hooks
        const testFailed = false;

        if (!verboseMode) {
            // Stop capturing
            logCapture.stop();

            // If test failed, dump all logs
            if (testFailed) {
                console.error(`\n===== LOGS FOR FAILED TEST: ${testKey} =====`);

                // Dump captured console logs
                logCapture.dump();

                // Dump server logs if any
                const serverLogs = testServerLogs.get(testKey);
                if (serverLogs && serverLogs.length > 0) {
                    console.error("\n----- Server Logs -----");
                    serverLogs.forEach(log => console.error(log));
                }

                // Dump client logs if any
                const clientLogs = testClientLogs.get(testKey);
                if (clientLogs && clientLogs.length > 0) {
                    console.error("\n----- Client Logs -----");
                    clientLogs.forEach(log => console.error(log));
                }

                console.error(`===== END LOGS =====\n`);
            }

            // Clear logs for this test
            logCapture.clear();
        }

        // Clean up test logs
        testServerLogs.delete(testKey);
        testClientLogs.delete(testKey);
        currentTestContext = null;
    });
}

/**
 * Add server logs for the current test
 * @param logs The server logs to add
 */
export function addServerLogs(logs: string | string[]): void {
    if (!currentTestContext) return;

    const testKey = `${currentTestContext.suiteName}::${currentTestContext.testName}`;
    const logsArray = Array.isArray(logs) ? logs : [logs];

    if (!testServerLogs.has(testKey)) {
        testServerLogs.set(testKey, []);
    }

    testServerLogs.get(testKey)!.push(...logsArray);
}

/**
 * Add client logs for the current test
 * @param logs The client logs to add
 */
export function addClientLogs(logs: string | string[]): void {
    if (!currentTestContext) return;

    const testKey = `${currentTestContext.suiteName}::${currentTestContext.testName}`;
    const logsArray = Array.isArray(logs) ? logs : [logs];

    if (!testClientLogs.has(testKey)) {
        testClientLogs.set(testKey, []);
    }

    testClientLogs.get(testKey)!.push(...logsArray);
}

/**
 * Get the current test context
 */
export function getCurrentTestContext(): TestContext | null {
    return currentTestContext;
}

/**
 * Mark the current test as failed and dump logs immediately
 * Use this when you detect a failure condition outside of assertions
 */
export function markTestFailed(reason?: string): void {
    if (!currentTestContext || isVerboseMode()) return;

    const testKey = `${currentTestContext.suiteName}::${currentTestContext.testName}`;
    const logCapture = getLogCapture();

    // Stop capturing temporarily
    logCapture.stop();

    console.error(`\n===== LOGS FOR FAILED TEST: ${testKey} =====`);
    if (reason) {
        console.error(`Reason: ${reason}`);
    }

    // Dump captured console logs
    logCapture.dump();

    // Dump server logs if any
    const serverLogs = testServerLogs.get(testKey);
    if (serverLogs && serverLogs.length > 0) {
        console.error("\n----- Server Logs -----");
        serverLogs.forEach(log => console.error(log));
    }

    // Dump client logs if any
    const clientLogs = testClientLogs.get(testKey);
    if (clientLogs && clientLogs.length > 0) {
        console.error("\n----- Client Logs -----");
        clientLogs.forEach(log => console.error(log));
    }

    console.error(`===== END LOGS =====\n`);

    // Resume capturing
    logCapture.start();
}