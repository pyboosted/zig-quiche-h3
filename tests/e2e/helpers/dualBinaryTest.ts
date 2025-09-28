import { describe } from "bun:test";
import { ServerBinaryType } from "./testUtils";
import { verboseLog } from "@helpers/logCapture";

/**
 * Run a test suite against both server binaries (static and dynamic)
 * This ensures both routing implementations work identically
 *
 * @param name - The name of the test suite
 * @param testFn - The test function that receives the binary type
 */
export function describeBoth(name: string, testFn: (binaryType: ServerBinaryType) => void): void {
    // Run tests with static binary (compile-time routing)
    describe(`${name} [static]`, () => {
        testFn(ServerBinaryType.Static);
    });

    // Run tests with dynamic binary (runtime routing)
    describe(`${name} [dynamic]`, () => {
        testFn(ServerBinaryType.Dynamic);
    });
}

/**
 * Run a test suite only against the static binary.
 * Use this when behavior does not differ between routing implementations.
 */
export function describeStatic(name: string, testFn: (binaryType: ServerBinaryType) => void): void {
    describe(name, () => {
        testFn(ServerBinaryType.Static);
    });
}

/**
 * Helper to get a descriptive name for the binary type
 */
export function getBinaryTypeName(binaryType: ServerBinaryType): string {
    return binaryType === ServerBinaryType.Static ? "static" : "dynamic";
}

/**
 * Helper to skip tests for a specific binary if needed
 * Useful when a feature is only available in one implementation
 */
export function skipForBinary(
    binaryType: ServerBinaryType,
    skipBinary: ServerBinaryType,
    testFn: () => void,
): void {
    if (binaryType === skipBinary) {
        verboseLog(`Skipping test for ${getBinaryTypeName(binaryType)} binary`);
        return;
    }
    testFn();
}
