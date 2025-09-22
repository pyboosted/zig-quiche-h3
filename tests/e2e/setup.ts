import { afterAll, beforeAll } from "bun:test";
import { cleanupOldFiles } from "./helpers/testUtils";
import { isVerboseMode, verboseLog } from "./helpers/logCapture";
// import { setupFailureCapture } from "./helpers/failureCapture";

// Display mode information
const verboseMode = isVerboseMode();
if (!verboseMode) {
    console.log("🤫 Running tests in quiet mode. Set H3_VERBOSE=1 to see all logs.");
} else {
    console.log("📢 Running tests in verbose mode. All logs will be displayed.");
}

// Note: Bun doesn't currently support detecting test failures in afterEach hooks,
// so we can't automatically display logs only for failed tests.
// Use H3_VERBOSE=1 to see all logs when debugging failures.
// setupFailureCapture();

verboseLog(`[E2E] setup.ts loaded at ${new Date().toISOString()}`);

/**
 * Global test setup - runs once before all test suites
 */
beforeAll(async () => {
    verboseLog(`[E2E] beforeAll starting at ${new Date().toISOString()}`);

    // Clean up old test files (older than 30 minutes)
    // This prevents infinite accumulation while preserving recent files for debugging
    verboseLog(`[E2E] Calling cleanupOldFiles(30) at ${new Date().toISOString()}`);
    await cleanupOldFiles(30);
    verboseLog(`[E2E] cleanupOldFiles(30) completed at ${new Date().toISOString()}`);

    verboseLog("Test environment initialized - old tmp files cleaned");
    verboseLog(`[E2E] beforeAll completed at ${new Date().toISOString()}`);
});

/**
 * Global test teardown - runs once after all test suites
 */
afterAll(async () => {
    verboseLog(`[E2E] afterAll starting at ${new Date().toISOString()}`);

    // Optional: Clean up files older than 5 minutes after test run
    // This gives time to inspect recent test artifacts if needed
    verboseLog(`[E2E] Calling cleanupOldFiles(5) at ${new Date().toISOString()}`);
    await cleanupOldFiles(5);
    verboseLog(`[E2E] cleanupOldFiles(5) completed at ${new Date().toISOString()}`);

    verboseLog(`[E2E] afterAll completed at ${new Date().toISOString()}`);
});
