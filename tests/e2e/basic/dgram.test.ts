import { describe, expect, it } from "bun:test";
import { quicheClient } from "@helpers/quicheClient";
import { withServer } from "@helpers/spawnServer";

describe("QUIC DATAGRAM echo", () => {
  it("echoes datagrams when enabled", async () => {
    await withServer(
      async ({ port }) => {
        // Send a simple GET with DATAGRAMs enabled
        const url = `https://127.0.0.1:${port}/`;
        const res = await quicheClient(url, {
          dumpJson: false,
          dgramProto: "oneway",
          dgramCount: 3,
        });

        console.log("Client output:", res.output);
        console.log("Client error:", res.error);
        console.log("Client success:", res.success);
        expect(res.success).toBeTrue();
        // quiche apps log received datagrams to stderr with RUST_LOG
        expect(res.error || res.output).toContain("Received DATAGRAM");
      },
      {
        env: { H3_DGRAM_ECHO: "1" },
      },
    );
  });

  it("does not echo datagrams when disabled", async () => {
    await withServer(
      async ({ port }) => {
        // Send a GET with DATAGRAMs but server has echo disabled
        const url = `https://127.0.0.1:${port}/`;
        const res = await quicheClient(url, {
          dumpJson: false,
          dgramProto: "oneway",
          dgramCount: 3,
        });

        expect(res.success).toBeTrue();
        // Server should not echo back any datagrams
        expect(res.error || "").not.toContain("Received DATAGRAM");
        // But client should still send datagrams (logged in stderr)
        expect(res.error || "").toContain("sending HTTP/3 DATAGRAM");
      },
      {
        // No H3_DGRAM_ECHO env var, so server disables datagram echo
      },
    );
  });
});
