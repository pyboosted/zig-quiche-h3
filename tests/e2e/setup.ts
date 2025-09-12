import { afterAll, beforeAll } from "bun:test";
import { cleanupOldFiles } from "./helpers/testUtils";

/**
 * Global test setup - runs once before all test suites
 */
beforeAll(async () => {
    // Clean up old test files (older than 30 minutes)
    // This prevents infinite accumulation while preserving recent files for debugging
    await cleanupOldFiles(30);
    
    console.log("Test environment initialized - old tmp files cleaned");
});

/**
 * Global test teardown - runs once after all test suites
 */
afterAll(async () => {
    // Optional: Clean up files older than 5 minutes after test run
    // This gives time to inspect recent test artifacts if needed
    await cleanupOldFiles(5);
});