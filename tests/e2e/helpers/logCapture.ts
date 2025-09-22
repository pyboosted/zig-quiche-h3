/**
 * Log capture utility for suppressing output during successful tests
 * Only shows logs when tests fail, keeping test output clean
 */

interface LogEntry {
    level: "log" | "error" | "warn" | "info" | "debug";
    args: any[];
    timestamp: number;
}

export class LogCapture {
    private logs: LogEntry[] = [];
    private originalConsole: {
        log: typeof console.log;
        error: typeof console.error;
        warn: typeof console.warn;
        info: typeof console.info;
        debug: typeof console.debug;
    };
    private isCapturing = false;

    constructor() {
        // Store original console methods
        this.originalConsole = {
            log: console.log.bind(console),
            error: console.error.bind(console),
            warn: console.warn.bind(console),
            info: console.info.bind(console),
            debug: console.debug.bind(console),
        };
    }

    /**
     * Start capturing console output
     */
    start(): void {
        if (this.isCapturing) return;

        this.logs = [];
        this.isCapturing = true;

        // Override console methods to capture output
        console.log = (...args: any[]) => {
            this.logs.push({ level: "log", args, timestamp: Date.now() });
        };

        console.error = (...args: any[]) => {
            this.logs.push({ level: "error", args, timestamp: Date.now() });
        };

        console.warn = (...args: any[]) => {
            this.logs.push({ level: "warn", args, timestamp: Date.now() });
        };

        console.info = (...args: any[]) => {
            this.logs.push({ level: "info", args, timestamp: Date.now() });
        };

        console.debug = (...args: any[]) => {
            this.logs.push({ level: "debug", args, timestamp: Date.now() });
        };
    }

    /**
     * Stop capturing and restore original console
     */
    stop(): void {
        if (!this.isCapturing) return;

        // Restore original console methods
        console.log = this.originalConsole.log;
        console.error = this.originalConsole.error;
        console.warn = this.originalConsole.warn;
        console.info = this.originalConsole.info;
        console.debug = this.originalConsole.debug;

        this.isCapturing = false;
    }

    /**
     * Get all captured logs
     */
    getLogs(): LogEntry[] {
        return [...this.logs];
    }

    /**
     * Clear captured logs
     */
    clear(): void {
        this.logs = [];
    }

    /**
     * Dump all captured logs to the real console
     */
    dump(prefix = ""): void {
        const originalState = this.isCapturing;

        // Temporarily stop capturing to dump logs
        if (originalState) {
            this.stop();
        }

        for (const entry of this.logs) {
            const method = this.originalConsole[entry.level];
            if (prefix) {
                method(prefix, ...entry.args);
            } else {
                method(...entry.args);
            }
        }

        // Resume capturing if it was active
        if (originalState) {
            this.start();
        }
    }

    /**
     * Format logs as a string
     */
    format(): string {
        return this.logs
            .map(entry => {
                const timestamp = new Date(entry.timestamp).toISOString();
                const level = entry.level.toUpperCase().padEnd(5);
                const message = entry.args
                    .map(arg => {
                        if (typeof arg === "object") {
                            try {
                                return JSON.stringify(arg);
                            } catch {
                                return String(arg);
                            }
                        }
                        return String(arg);
                    })
                    .join(" ");
                return `[${timestamp}] ${level} ${message}`;
            })
            .join("\n");
    }
}

// Global instance
let globalCapture: LogCapture | null = null;

/**
 * Get or create the global log capture instance
 */
export function getLogCapture(): LogCapture {
    if (!globalCapture) {
        globalCapture = new LogCapture();
    }
    return globalCapture;
}

/**
 * Check if verbose mode is enabled
 */
export function isVerboseMode(): boolean {
    return process.env.H3_VERBOSE === "1" || process.env.H3_VERBOSE === "true";
}

/**
 * Log a message only in verbose mode
 */
export function verboseLog(...args: any[]): void {
    if (isVerboseMode()) {
        console.log(...args);
    }
}