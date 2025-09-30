#!/usr/bin/env bun
// Manual test script for stats API (avoiding Bun canary test framework segfault)
import { createH3Server } from "../../src/bun/server.ts";
import { getCertPath } from "../e2e/helpers/testUtils";

const HOST = "127.0.0.1";
const PORT = 44999;

console.log("Creating server...");
const server = createH3Server({
  hostname: HOST,
  port: PORT,
  certPath: getCertPath("cert.crt"),
  keyPath: getCertPath("cert.key"),
  fetch: async () => new Response("ok"),
});

console.log("Getting initial stats...");
const stats = server.getStats();
console.log("Initial stats:", {
  connectionsTotal: stats.connectionsTotal.toString(),
  connectionsActive: stats.connectionsActive.toString(),
  requests: stats.requests.toString(),
  uptimeMs: stats.uptimeMs.toString(),
});

// Verify stats structure
if (typeof stats.connectionsTotal === "bigint" &&
    typeof stats.connectionsActive === "bigint" &&
    typeof stats.requests === "bigint" &&
    typeof stats.uptimeMs === "bigint") {
  console.log("✅ Stats API working correctly - all fields are bigint");
} else {
  console.error("❌ Stats API broken - fields have wrong types");
  process.exit(1);
}

// Verify initial values
if (stats.connectionsTotal === 0n &&
    stats.connectionsActive === 0n &&
    stats.requests === 0n &&
    stats.uptimeMs >= 0n) {
  console.log("✅ Initial stats values are correct");
} else {
  console.error("❌ Initial stats have unexpected values");
  process.exit(1);
}

console.log("Closing server...");
server.close();
console.log("✅ All checks passed!");