import { expect, it } from "bun:test";
import { describeBoth } from "@helpers/dualBinaryTest";
import { withServer } from "@helpers/spawnServer";
import type { ServerBinaryType } from "@helpers/testUtils";
import { zigClient } from "@helpers/zigClient";

describeBoth("QUIC DATAGRAM echo", (_binaryType: ServerBinaryType) => {
    it("echoes datagrams when enabled", async () => {
        await withServer(
            async ({ port }) => {
                const url = `https://127.0.0.1:${port}/h3dgram/echo`;
                const res = await zigClient(url, {
                    h3Dgram: true,
                    dgramPayload: "test-dgram-payload",
                    dgramCount: 3,
                    dgramIntervalMs: 0,
                    curlCompat: false,
                });

                const output = res.raw;
                // Direct assertion without retry - test should be deterministic
                expect(output).toContain("event=datagram");

                // Verify we received echo datagrams (could be less than sent due to UDP nature)
                const datagramEvents = output.match(/event=datagram/g);
                expect(datagramEvents).toBeTruthy();
                expect(datagramEvents!.length).toBeGreaterThan(0);
            },
            {
                env: { H3_DGRAM_ECHO: "1", RUST_LOG: "debug" },
            },
        );
    });

    it("does not echo datagrams when disabled", async () => {
        await withServer(
            async ({ port }) => {
                const url = `https://127.0.0.1:${port}/`;
                const res = await zigClient(url, {
                    h3Dgram: true,
                    dgramPayload: "test-dgram-payload",
                    dgramCount: 2,
                    dgramIntervalMs: 50,
                    dgramWaitMs: 200,
                    curlCompat: false,
                });

                const output = res.raw;
                expect(output).not.toContain("event=datagram");
                expect(res.status).toBe(200);
            },
            {
                // No H3_DGRAM_ECHO env var, so server disables datagram echo
            },
        );
    });
});
