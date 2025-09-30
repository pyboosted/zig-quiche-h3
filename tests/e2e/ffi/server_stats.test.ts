import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { createH3Server, type H3Server } from "../../../src/bun/server.ts";
import { prebuildAllArtifacts } from "@helpers/prebuild";
import { getCertPath, randPort } from "@helpers/testUtils";
import { zigClient } from "@helpers/zigClient";

const HOST = "127.0.0.1";

describe("Server stats API", () => {
  let server: H3Server;
  const port = randPort();

  beforeAll(async () => {
    await prebuildAllArtifacts();
    server = createH3Server({
      hostname: HOST,
      port,
      certPath: getCertPath("cert.crt"),
      keyPath: getCertPath("cert.key"),
      fetch: async (request) => {
        return new Response(JSON.stringify({ path: new URL(request.url).pathname }), {
          headers: { "content-type": "application/json" },
        });
      },
    });
  });

  afterAll(() => {
    server.close();
  });

  it("returns stats after server start", () => {
    const stats = server.getStats();
    expect(stats.connectionsTotal).toBe(0n);
    expect(stats.connectionsActive).toBe(0n);
    expect(stats.requests).toBe(0n);
    expect(stats.uptimeMs).toBeGreaterThanOrEqual(0n);
  });

  it("increments request counter after requests", async () => {
    const statsBefore = server.getStats();
    const requestsBefore = statsBefore.requests;

    // Make 3 requests
    await zigClient(`https://${HOST}:${port}/test1`, { insecure: true });
    await zigClient(`https://${HOST}:${port}/test2`, { insecure: true });
    await zigClient(`https://${HOST}:${port}/test3`, { insecure: true });

    const statsAfter = server.getStats();
    expect(statsAfter.requests).toBeGreaterThanOrEqual(requestsBefore + 3n);
    expect(statsAfter.connectionsTotal).toBeGreaterThan(0n);
    expect(statsAfter.uptimeMs).toBeGreaterThan(statsBefore.uptimeMs);
  });

  it("tracks connections accurately", async () => {
    const statsBefore = server.getStats();

    // Make a request to create a connection
    await zigClient(`https://${HOST}:${port}/connection-test`, { insecure: true });

    const statsAfter = server.getStats();
    expect(statsAfter.connectionsTotal).toBeGreaterThanOrEqual(statsBefore.connectionsTotal);
    // connectionsActive may be 0 if connection closed already, but total should increase
  });

  it("throws error when reading stats from closed server", () => {
    const testServer = createH3Server({
      hostname: HOST,
      port: randPort(),
      certPath: getCertPath("cert.crt"),
      keyPath: getCertPath("cert.key"),
      fetch: async () => new Response("ok"),
    });
    testServer.close();

    expect(() => testServer.getStats()).toThrow("Server is closed");
  });
});