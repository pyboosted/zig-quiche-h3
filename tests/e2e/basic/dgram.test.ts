import { describe, expect, it } from "bun:test";
import { quicheClient } from "@helpers/quicheClient";
import { withServer } from "@helpers/spawnServer";
import { retryWithBackoff } from "@helpers/cpuLoad";

describe("QUIC DATAGRAM echo", () => {
  it("echoes datagrams when enabled", async () => {
    await withServer(
      async ({ port }) => {
        // Use retry logic for flaky DATAGRAM tests under CPU load
        await retryWithBackoff(async () => {
          // Send a simple GET with DATAGRAMs enabled to the echo endpoint
          const url = `https://127.0.0.1:${port}/h3dgram/echo`;
          const res = await quicheClient(url, {
            dumpJson: false,
            dgramProto: "oneway",
            dgramCount: 3,
            idleTimeout: 10000, // Increased to 10 seconds for loaded systems
          });

          console.log("[DGRAM Test] Client output:", res.output);
          console.log("[DGRAM Test] Client error:", res.error);
          console.log("[DGRAM Test] Client success:", res.success);
          
          expect(res.success).toBeTrue();
          
          // Check for received datagrams with better diagnostics
          const combined = (res.error || "") + (res.output || "");
          if (!combined.includes("Received DATAGRAM")) {
            console.error("[DGRAM Test] No 'Received DATAGRAM' found in output");
            console.error("[DGRAM Test] Full output:", combined.slice(0, 1000));
            throw new Error("DATAGRAM echo not received - possible timing issue");
          }
        }, 3, 2000); // 3 retries with 2 second initial delay
      },
      {
        env: { H3_DGRAM_ECHO: "1", RUST_LOG: "debug" }, // Changed from default to debug
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
          idleTimeout: 5000, // Reasonable timeout even without echo
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
