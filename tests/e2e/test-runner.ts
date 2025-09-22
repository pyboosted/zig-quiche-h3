/**
 * Main test runner with automatic cleanup
 * This file should be imported at the top of each test suite
 */
import { beforeAll } from "bun:test";
import { cleanupOldFiles } from "./helpers/testUtils";
import { verboseLog } from "@helpers/logCapture";

// Global setup that runs once per test file
let cleanupDone = false;

beforeAll(async () => {
    if (!cleanupDone) {
        // Clean up old test files (older than 30 minutes)
        // This prevents infinite accumulation while preserving recent files for debugging
        await cleanupOldFiles(30);
        cleanupDone = true;
        verboseLog("✓ Old tmp files cleaned (>30 min)");
    }
});

// Export for tests that need manual cleanup
export { cleanupAll, cleanupOldFiles, getTmpDir } from "./helpers/testUtils";
