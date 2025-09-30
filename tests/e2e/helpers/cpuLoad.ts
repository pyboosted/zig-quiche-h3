import { verboseLog } from "./logCapture";

/**
 * CPU load simulation utilities for testing race conditions
 */

/**
 * Simulate CPU load by performing intensive calculations
 */
export function simulateCpuLoad(durationMs: number): Promise<void> {
    return new Promise((resolve) => {
        const startTime = Date.now();

        // Spawn multiple workers to consume CPU
        const numWorkers = navigator?.hardwareConcurrency || 4;
        let completed = 0;

        for (let i = 0; i < numWorkers; i++) {
            setTimeout(() => {
                // Intensive calculation in each "worker"
                while (Date.now() - startTime < durationMs) {
                    // Prime number calculation to consume CPU
                    const n = 1000000;
                    for (let j = 2; j < n; j++) {
                        let _isPrime = true;
                        for (let k = 2; k * k <= j; k++) {
                            if (j % k === 0) {
                                _isPrime = false;
                                break;
                            }
                        }
                    }
                }

                completed++;
                if (completed === numWorkers) {
                    resolve();
                }
            }, 0);
        }

        // Fallback timeout
        setTimeout(resolve, durationMs + 100);
    });
}

/**
 * Run a test with simulated CPU load
 */
export async function withCpuLoad<T>(loadMs: number, testFn: () => Promise<T>): Promise<T> {
    // Start CPU load in background
    const loadPromise = simulateCpuLoad(loadMs);

    try {
        // Run the test
        const result = await testFn();

        // Wait for load to complete
        await loadPromise;

        return result;
    } catch (error) {
        // Ensure load completes even on error
        await loadPromise;
        throw error;
    }
}

/**
 * Run a command with reduced CPU priority using nice
 */
export function niceCommand(cmd: string[], niceness: number = 10): string[] {
    return ["nice", `-n${niceness}`, ...cmd];
}

/**
 * Add retry logic with exponential backoff
 */
export async function retryWithBackoff<T>(
    fn: () => Promise<T>,
    maxRetries: number = 3,
    initialDelayMs: number = 1000,
): Promise<T> {
    let lastError: unknown;

    for (let i = 0; i < maxRetries; i++) {
        try {
            return await fn();
        } catch (error) {
            lastError = error;

            if (i < maxRetries - 1) {
                const delay = initialDelayMs * 2 ** i;
                verboseLog(`Retry ${i + 1}/${maxRetries} after ${delay}ms delay...`);
                await new Promise((resolve) => setTimeout(resolve, delay));
            }
        }
    }

    throw lastError;
}
