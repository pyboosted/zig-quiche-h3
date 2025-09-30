import { expect, test, beforeAll, afterAll } from "bun:test";
import { H3Server } from "../../../src/bun/server";
import { zigClient } from "@helpers/zigClient";

let server: H3Server | null = null;
const PORT = 4435;

beforeAll(async () => {
  // Create server with H3 DATAGRAM route
  server = new H3Server({
    port: PORT,
    certPath: "third_party/quiche/quiche/examples/cert.crt",
    keyPath: "third_party/quiche/quiche/examples/cert.key",
    routes: [
      {
        method: "POST",
        pattern: "/h3dgram/echo",
        h3Datagram: (payload, ctx) => {
          // Echo back the datagram
          ctx.sendReply(payload);
        },
        fetch: (req) => {
          return new Response("H3 DATAGRAM echo route ready\n", {
            status: 200,
            headers: { "content-type": "text/plain" },
          });
        },
      },
    ],
    fetch: (req) => {
      return new Response("Default handler", {
        status: 200,
        headers: { "content-type": "text/plain" },
      });
    },
  });

  // Wait for server to be ready
  await new Promise((resolve) => setTimeout(resolve, 100));
});

afterAll(async () => {
  if (server) {
    server.stop();
    server.close();
  }
});

test("H3 DATAGRAM echo via FFI server", async () => {
  // Test basic GET request to H3 DATAGRAM endpoint
  const response = await zigClient(`https://127.0.0.1:${PORT}/h3dgram/echo`, {
    method: "GET",
    maxTime: 5,
  });

  expect(response.status).toBe(200);
  expect(response.body).toContain("H3 DATAGRAM echo route ready");
});

test("H3 DATAGRAM send and receive echo", async () => {
  // Send H3 DATAGRAMs and verify echoes
  const response = await zigClient(`https://127.0.0.1:${PORT}/h3dgram/echo`, {
    method: "POST",
    h3Dgram: true,
    dgramPayload: "test-payload",
    dgramCount: 3,
    dgramIntervalMs: 10,
    waitForDgrams: 3,
    maxTime: 10,
  });

  expect(response.status).toBe(200);

  // Verify we received datagram events
  const rawText = response.raw;
  expect(rawText).toContain("event=datagram");

  // Count datagram events
  const datagramEvents = rawText.match(/event=datagram/g);
  expect(datagramEvents).toBeTruthy();
  expect(datagramEvents!.length).toBeGreaterThanOrEqual(3);

  // Verify flow_id is present
  expect(rawText).toContain("flow");
});

test("H3 DATAGRAM with large payload", async () => {
  // Test with larger payload (up to MTU limit)
  const largePayload = "x".repeat(1000);

  const response = await zigClient(`https://127.0.0.1:${PORT}/h3dgram/echo`, {
    method: "POST",
    h3Dgram: true,
    dgramPayload: largePayload,
    dgramCount: 2,
    waitForDgrams: 2,
    maxTime: 10,
  });

  expect(response.status).toBe(200);

  const rawText = response.raw;
  expect(rawText).toContain("event=datagram");

  const datagramEvents = rawText.match(/event=datagram/g);
  expect(datagramEvents).toBeTruthy();
  expect(datagramEvents!.length).toBeGreaterThanOrEqual(2);
});