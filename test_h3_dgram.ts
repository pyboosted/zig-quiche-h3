#!/usr/bin/env bun
import { H3Server } from "./src/bun/server";

console.log("Starting H3 DATAGRAM echo server...");

const server = new H3Server({
  port: 4434,
  certPath: "third_party/quiche/quiche/examples/cert.crt",
  keyPath: "third_party/quiche/quiche/examples/cert.key",
  routes: [
    {
      method: "POST",
      pattern: "/h3dgram/echo",
      h3Datagram: (payload, ctx) => {
        console.log(
          `[H3 DATAGRAM] Received ${payload.length} bytes on stream ${ctx.streamId}, flow ${ctx.flowId}`,
        );
        console.log(`[H3 DATAGRAM] Payload: ${new TextDecoder().decode(payload)}`);
        // Echo back
        ctx.sendReply(payload);
        console.log(`[H3 DATAGRAM] Echoed back ${payload.length} bytes`);
      },
      fetch: (req) => {
        return new Response("H3 DATAGRAM echo route ready", {
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

console.log(`Server listening on https://0.0.0.0:${server.port}`);
console.log("Test with: ./zig-out/bin/h3-client --url https://127.0.0.1:4434/h3dgram/echo --h3-dgram --dgram-payload 'test' --insecure");

// Keep server running
process.on("SIGINT", () => {
  console.log("\nShutting down...");
  server.stop();
  process.exit(0);
});