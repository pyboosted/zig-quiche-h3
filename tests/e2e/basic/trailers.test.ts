import { expect, test } from "bun:test";
import { describeBoth } from "@helpers/dualBinaryTest";
import { spawnServer } from "@helpers/spawnServer";
import type { ServerBinaryType } from "@helpers/testUtils";
import { spawn } from "bun";

describeBoth("HTTP/3 Trailers", (binaryType: ServerBinaryType) => {
    test("curl trace shows response trailers", async () => {
        const server = await spawnServer({ binaryType });
        try {
            const url = `https://127.0.0.1:${server.port}/trailers/demo`;

            // Use curl trace-ascii to capture trailing headers in a stable way
            const proc = spawn({
                cmd: ["curl", "-sk", "--http3-only", "--trace-ascii", "-", url],
                stdout: "pipe",
                stderr: "pipe",
            });

            await proc.exited;
            const trace = await new Response(proc.stdout).text();
            const err = await new Response(proc.stderr).text();

            // Basic sanity: curl exited successfully or at least produced output
            expect(trace.length + err.length).toBeGreaterThan(0);

            // Trailers should be present in the trace output
            // We sent: x-demo-trailer: finished
            const combined = `${trace}\n${err}`;
            expect(combined.toLowerCase()).toContain("x-demo-trailer: finished");
        } finally {
            await server.cleanup();
        }
    });
});
