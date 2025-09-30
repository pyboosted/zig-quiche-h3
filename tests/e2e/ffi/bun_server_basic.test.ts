import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { createH3Server, type H3Server } from "../../../src/bun/server.ts";
import { prebuildAllArtifacts } from "@helpers/prebuild";
import { getCertPath, randPort } from "@helpers/testUtils";
import { zigClient } from "@helpers/zigClient";

const HOST = "127.0.0.1";

describe("Bun FFI server integration", () => {
    let server: H3Server;
    const port = randPort();

    beforeAll(async () => {
        await prebuildAllArtifacts();
        server = createH3Server({
            hostname: HOST,
            port,
            certPath: getCertPath("cert.crt"),
            keyPath: getCertPath("cert.key"),
            enableDatagram: true,
            fetch: async (request) => {
                const url = new URL(request.url);
                if (url.pathname === "/json") {
                    return new Response(JSON.stringify({ ok: true, path: url.pathname }), {
                        headers: {
                            "content-type": "application/json",
                        },
                    });
                }

                if (url.pathname === "/stream") {
                    const encoder = new TextEncoder();
                    const chunks = ["one", "two", "three"].map((part) => encoder.encode(`${part}\n`));
                    const stream = new ReadableStream<Uint8Array>({
                        start(controller) {
                            for (const chunk of chunks) controller.enqueue(chunk);
                            controller.close();
                        },
                    });
                    return new Response(stream, {
                        headers: {
                            "content-type": "text/plain; charset=utf-8",
                        },
                    });
                }

                return new Response("hello from bun ffi server", {
                    headers: {
                        "content-type": "text/plain; charset=utf-8",
                    },
                });
            },
        });
    });

    afterAll(() => {
        server.close();
    });

    it("serves basic GET requests", async () => {
        const res = await zigClient(`https://${HOST}:${port}/`, {
            insecure: true,
            outputBody: true,
        });
        const bodyText = new TextDecoder().decode(res.body ?? new Uint8Array());
        expect(res.status).toBe(200);
        expect(bodyText).toBe("hello from bun ffi server");
    });

    it("streams chunked responses", async () => {
        const res = await zigClient(`https://${HOST}:${port}/stream`, {
            insecure: true,
            outputBody: true,
        });
        const bodyText = new TextDecoder().decode(res.body ?? new Uint8Array());
        expect(res.status).toBe(200);
        expect(bodyText.split("\n").filter(Boolean)).toEqual(["one", "two", "three"]);
    });

    it("returns JSON payloads", async () => {
        const res = await zigClient(`https://${HOST}:${port}/json`, {
            insecure: true,
            outputBody: true,
        });
        const bodyText = new TextDecoder().decode(res.body ?? new Uint8Array());
        expect(res.status).toBe(200);
        expect(res.headers.get("content-type") ?? "").toContain("application/json");
        const data = JSON.parse(bodyText) as { ok: boolean; path: string };
        expect(data).toEqual({ ok: true, path: "/json" });
    });
});
