import { afterAll, beforeAll } from "bun:test";
import { cleanupOldFiles } from "./helpers/testUtils";

console.log(`[E2E] setup.ts loaded at ${new Date().toISOString()}`);

/**
 * Global test setup - runs once before all test suites
 */
beforeAll(async () => {
    console.log(`[E2E] beforeAll starting at ${new Date().toISOString()}`);

    // Clean up old test files (older than 30 minutes)
    // This prevents infinite accumulation while preserving recent files for debugging
    console.log(`[E2E] Calling cleanupOldFiles(30) at ${new Date().toISOString()}`);
    await cleanupOldFiles(30);
    console.log(`[E2E] cleanupOldFiles(30) completed at ${new Date().toISOString()}`);

    console.log("Test environment initialized - old tmp files cleaned");
    console.log(`[E2E] beforeAll completed at ${new Date().toISOString()}`);
});

/**
 * Global test teardown - runs once after all test suites
 */
afterAll(async () => {
    console.log(`[E2E] afterAll starting at ${new Date().toISOString()}`);

    // Optional: Clean up files older than 5 minutes after test run
    // This gives time to inspect recent test artifacts if needed
    console.log(`[E2E] Calling cleanupOldFiles(5) at ${new Date().toISOString()}`);
    await cleanupOldFiles(5);
    console.log(`[E2E] cleanupOldFiles(5) completed at ${new Date().toISOString()}`);

    console.log(`[E2E] afterAll completed at ${new Date().toISOString()}`);
});
