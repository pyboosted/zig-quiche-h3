import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { describeBoth } from "@helpers/dualBinaryTest";
import { type ServerInstance, spawnServer } from "@helpers/spawnServer";
import { expectJson, type ServerBinaryType } from "@helpers/testUtils";
import { get, post } from "@helpers/zigClient";

console.log(`[E2E] routing.test.ts loaded at ${new Date().toISOString()}`);

describeBoth("HTTP/3 Routing", (binaryType: ServerBinaryType) => {
    console.log(
        `[E2E] describe("HTTP/3 Routing [${binaryType}]") executed at ${new Date().toISOString()}`,
    );
    let server: ServerInstance;

    beforeAll(async () => {
        console.log(
            `[E2E] routing.test.ts beforeAll(${binaryType}) starting at ${new Date().toISOString()}`,
        );
        server = await spawnServer({ qlog: false, binaryType });
        console.log(
            `[E2E] routing.test.ts beforeAll(${binaryType}) completed at ${new Date().toISOString()}`,
        );
    });

    afterAll(async () => {
        console.log(
            `[E2E] routing.test.ts afterAll(${binaryType}) starting at ${new Date().toISOString()}`,
        );
        await server.cleanup();
        console.log(
            `[E2E] routing.test.ts afterAll(${binaryType}) completed at ${new Date().toISOString()}`,
        );
    });

    describe("Static routes", () => {
        it("GET / matches exact static route", async () => {
            const response = await get(`https://127.0.0.1:${server.port}/`);

            expect(response.status).toBe(200);
            expect(response.headers.get("content-type")).toContain("text/html");

            const body = new TextDecoder().decode(response.body);
            expect(body).toContain("Welcome to Zig QUIC/HTTP3 Server!");
        });

        it("GET /api/users matches exact static route", async () => {
            const response = await get(`https://127.0.0.1:${server.port}/api/users`);

            expect(response.status).toBe(200);
            expect(response.headers.get("content-type")).toContain("application/json");

            const json = JSON.parse(new TextDecoder().decode(response.body));
            expect(Array.isArray(json)).toBe(true);
        });
    });

    describe("Parameterized routes", () => {
        it("GET /api/users/:id extracts numeric ID", async () => {
            const response = await get(`https://127.0.0.1:${server.port}/api/users/42`);

            expect(response.status).toBe(200);
            expect(response.headers.get("content-type")).toContain("application/json");

            const json = JSON.parse(new TextDecoder().decode(response.body));
            expectJson(json, { id: "", name: "" });
            expect(json.id).toBe("42");
            expect(typeof json.name).toBe("string");
        });

        it("GET /api/users/:id extracts string ID", async () => {
            const response = await get(`https://127.0.0.1:${server.port}/api/users/abc123`);

            expect(response.status).toBe(200);
            const json = JSON.parse(new TextDecoder().decode(response.body));

            // Should parse as number or handle as string appropriately
            expect(json.id).toBeDefined();
        });

        it("GET /api/users/:id handles special characters", async () => {
            // URL encode special characters
            const userId = encodeURIComponent("user@domain.com");
            const response = await get(`https://127.0.0.1:${server.port}/api/users/${userId}`);

            expect(response.status).toBe(200);
        });
    });

    describe("Wildcard routes", () => {
        it("GET /files/* captures remaining path", async () => {
            const response = await get(`https://127.0.0.1:${server.port}/files/test.txt`);

            expect(response.status).toBe(200);
            expect(response.headers.get("content-type")).toContain("application/json");

            const json = JSON.parse(new TextDecoder().decode(response.body));
            expect(json.requested_file).toBe("test.txt");
        });

        it("GET /files/* captures nested path", async () => {
            const response = await get(`https://127.0.0.1:${server.port}/files/docs/readme.md`);

            expect(response.status).toBe(200);
            const json = JSON.parse(new TextDecoder().decode(response.body));
            expect(json.requested_file).toBe("docs/readme.md");
        });

        it("GET /files/* handles empty path", async () => {
            const response = await get(`https://127.0.0.1:${server.port}/files/`);

            expect(response.status).toBe(200);
            const json = JSON.parse(new TextDecoder().decode(response.body));
            expect(json.requested_file).toBe("");
        });

        it("GET /files/* captures query parameters", async () => {
            const response = await get(
                `https://127.0.0.1:${server.port}/files/data.json?format=pretty`,
            );

            expect(response.status).toBe(200);
            const json = JSON.parse(new TextDecoder().decode(response.body));
            expect(json.requested_file).toBe("data.json");
            // Query parameters should be handled separately from path matching
        });
    });

    describe("Route specificity", () => {
        it("More specific routes take precedence over wildcards", async () => {
            // /api/users should match before /api/* if such route exists
            const response = await get(`https://127.0.0.1:${server.port}/api/users`);

            expect(response.status).toBe(200);
            expect(response.headers.get("content-type")).toContain("application/json");

            // Should return array, not wildcard response
            const json = JSON.parse(new TextDecoder().decode(response.body));
            expect(Array.isArray(json)).toBe(true);
        });

        it("Parameterized routes work with specificity", async () => {
            // /api/users/123 should match :id pattern
            const response = await get(`https://127.0.0.1:${server.port}/api/users/999`);

            expect(response.status).toBe(200);
            const json = JSON.parse(new TextDecoder().decode(response.body));
            expect(json.id).toBe("999");
        });
    });

    describe("Method-specific routing", () => {
        it("Different methods can have different handlers", async () => {
            // GET /api/users returns array
            const getResponse = await get(`https://127.0.0.1:${server.port}/api/users`);
            expect(getResponse.status).toBe(200);

            const getJson = JSON.parse(new TextDecoder().decode(getResponse.body));
            expect(Array.isArray(getJson)).toBe(true);

            // POST /api/users creates user (different response)
            const postResponse = await post(
                `https://127.0.0.1:${server.port}/api/users`,
                JSON.stringify({ name: "Test" }),
                {
                    headers: { "content-type": "application/json" },
                },
            );
            // POST should create a user and return different response
            expect(postResponse.status).toBe(201);

            const postJson = JSON.parse(new TextDecoder().decode(postResponse.body));
            expect(postJson.message).toBe("User created");
        });
    });

    describe("Edge cases", () => {
        it("Handles URLs with trailing slashes", async () => {
            const response = await get(`https://127.0.0.1:${server.port}/api/users/`);

            // Should either match wildcard or return 404, but not crash
            expect([200, 404]).toContain(response.status);
        });

        it("Handles double slashes in URLs", async () => {
            const response = await get(`https://127.0.0.1:${server.port}//api//users`);

            // Should normalize or handle gracefully
            expect([200, 404]).toContain(response.status);
        });

        it("Handles very long URLs", async () => {
            const longPath = "x".repeat(1000);
            const response = await get(`https://127.0.0.1:${server.port}/files/${longPath}`);

            // Should handle long paths without crashing
            expect([200, 404, 414]).toContain(response.status); // 414 = URI Too Long
        });

        it("Handles URL-encoded parameters", async () => {
            const encodedParam = encodeURIComponent("hello world");
            const response = await get(
                `https://127.0.0.1:${server.port}/api/users/${encodedParam}`,
            );

            // URL-encoded parameters should work, but complex ones with slashes might not
            expect([200, 404]).toContain(response.status);
            // Parameter should be decoded correctly by the server
        });
    });
});
