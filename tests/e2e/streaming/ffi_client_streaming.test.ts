import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { spawnServer } from "@helpers/spawnServer";
import type { ServerInstance } from "@helpers/spawnServer";
import {
  createClient,
  connectClient,
  fetchStreaming,
  freeClient,
  type FetchEventRecord,
} from "@helpers/ffiClient";

const STARTED_EVENT = 5;
const HEADERS_EVENT = 0;
const DATA_EVENT = 1;
const FINISHED_EVENT = 3;
const DATAGRAM_EVENT = 4;

describe("FFI client streaming callbacks", () => {
  let server: ServerInstance;

  beforeAll(async () => {
    server = await spawnServer({});
  });

  afterAll(async () => {
    await server.cleanup();
  });

  it("emits streaming events for slow handler", () => {
    const client = createClient({ enableDatagram: true, verifyPeer: false });
    try {
      connectClient(client, "127.0.0.1", server.port, "127.0.0.1");
      const result = fetchStreaming(client, {
        path: `/slow?delay=25`,
        collectBody: false,
      });

      expect(result.status).toBe(200);
      const eventTypes = result.events.map((ev) => ev.type);
      expect(eventTypes).toContain(STARTED_EVENT);
      expect(eventTypes).toContain(HEADERS_EVENT);
      expect(eventTypes).toContain(DATA_EVENT);
      expect(eventTypes[eventTypes.length - 1]).toBe(FINISHED_EVENT);

      const receivedBytes = result.events
        .filter((ev) => ev.type === DATA_EVENT && ev.data)
        .reduce((total, ev) => total + (ev.data?.length ?? 0), 0);

      const expectedBody = new TextEncoder().encode(
        "Slow response completed\n",
      );
      expect(receivedBytes).toBe(expectedBody.length);
      expect(result.body.length).toBe(0);
    } finally {
      freeClient(client);
    }
  });

  it("delivers echoed H3 datagrams", () => {
    const client = createClient({ enableDatagram: true, verifyPeer: false });
    try {
      connectClient(client, "127.0.0.1", server.port, "127.0.0.1");
      const payload = new TextEncoder().encode("ffi-dgram-test");
      let sent = false;

      const result = fetchStreaming(client, {
        path: "/h3dgram/echo",
        collectBody: false,
        onEvent(record: FetchEventRecord, sendDatagram) {
          if (!sent && record.type === STARTED_EVENT) {
            sendDatagram(payload);
            sent = true;
          }
        },
      });

      expect(result.status).toBe(200);
      const datagramEvents = result.events.filter(
        (ev) => ev.type === DATAGRAM_EVENT && ev.data,
      );
      expect(datagramEvents.length).toBeGreaterThan(0);
      const echoed = datagramEvents[0]!.data!;
      expect(Buffer.from(echoed).equals(Buffer.from(payload))).toBe(true);
    } finally {
      freeClient(client);
    }
  });
});
