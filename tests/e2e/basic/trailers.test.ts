import { expect, test } from "bun:test";
import { describeStatic } from "@helpers/dualBinaryTest";
import { spawnServer } from "@helpers/spawnServer";
import type { ServerBinaryType } from "@helpers/testUtils";
import { zigClient } from "@helpers/zigClient";

describeStatic("HTTP/3 Trailers", (binaryType: ServerBinaryType) => {
    test("curl trace shows response trailers", async () => {
        const server = await spawnServer({ binaryType });
        try {
            const url = `https://127.0.0.1:${server.port}/trailers/demo`;

            const response = await zigClient(url, { curlCompat: false });

            const output = response.raw.toLowerCase();
            expect(output.length).toBeGreaterThan(0);
            expect(output).toContain("trailers:");
            expect(output).toContain("x-demo-trailer: finished");
        } finally {
            await server.cleanup();
        }
    });
});
