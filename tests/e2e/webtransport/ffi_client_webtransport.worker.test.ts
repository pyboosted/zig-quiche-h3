import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import {
    createClient,
    connectClient,
    freeClient,
    pollClient,
    runClientOnce,
    openWebTransportSession,
    closeWebTransportSession,
    sendWebTransportDatagram,
    receiveWebTransportDatagram,
    freeWebTransportSession,
    isWebTransportEstablished,
    getWebTransportStreamId,
    type ClientHandle,
    type WebTransportEvent,
} from "@helpers/ffiClient";
import { spawnServer, type ServerInstance } from "@helpers/spawnServer";

const suite = process.env.H3_E2E_RUN_WORKER === "1" ? describe : describe.skip;

const encoder = new TextEncoder();

async function waitForCondition(
    client: ClientHandle,
    predicate: () => boolean,
    timeoutMs = 2000,
): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        pollClient(client);
        if (predicate()) return;
        await Bun.sleep(10);
    }
    throw new Error("Condition not met before timeout");
}

suite("FFI WebTransport client (worker)", () => {
    let server: ServerInstance;

    beforeAll(async () => {
        server = await spawnServer({
            env: {
                H3_WEBTRANSPORT: "1",
            },
        });
    });

    afterAll(async () => {
        await server.cleanup();
    });

    it("establishes a session and echoes datagrams", async () => {
        const client = createClient({
            enableDatagram: true,
            enableWebTransport: true,
            verifyPeer: false,
        });
        try {
            connectClient(client, "127.0.0.1", server.port, "127.0.0.1");

            const events: WebTransportEvent[] = [];
            const session = openWebTransportSession(client, "/wt/echo", (event) => {
                events.push(event);
            });

            await waitForCondition(client, () => events.some((ev) => ev.type === "connected"));
            expect(isWebTransportEstablished(session)).toBe(true);
            expect(getWebTransportStreamId(session)).toBeGreaterThanOrEqual(0n);

            const payload = encoder.encode("ffi-wt-dgram");
            sendWebTransportDatagram(session, payload);

            let received: Uint8Array | null = null;
            const deadline = Date.now() + 2000;
            while (Date.now() < deadline) {
                pollClient(client);
                received = receiveWebTransportDatagram(session);
                if (received) break;
                await Bun.sleep(10);
            }
            expect(received).not.toBeNull();
            expect(Buffer.from(received!)).toEqual(Buffer.from(payload));
            expect(events.some((ev) => ev.type === "datagram")).toBe(true);

            const closeReason = encoder.encode("client-close");
            closeWebTransportSession(session, { errorCode: 0, reason: closeReason });
            await waitForCondition(client, () => events.some((ev) => ev.type === "closed"));
            freeWebTransportSession(session);
        } finally {
            runClientOnce(client);
            freeClient(client);
        }
    });
});
