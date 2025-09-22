import { afterAll, beforeAll, expect, it } from "bun:test";
import { describeBoth } from "@helpers/dualBinaryTest";
import { type ServerInstance, spawnServer } from "@helpers/spawnServer";
import { expectJson, parseContentLength, type ServerBinaryType } from "@helpers/testUtils";
import { get, head, post, zigClient } from "@helpers/zigClient";
import { initTestReporter } from "@helpers/testReporter";

describeBoth("HTTP/3 Basic", (binaryType: ServerBinaryType) => {
    // Initialize test reporter for this suite
    initTestReporter("HTTP/3 Basic");

    let server: ServerInstance;

    beforeAll(async () => {
        server = await spawnServer({ qlog: false, binaryType });
    });

    afterAll(async () => {
        await server.cleanup();
    });

    it("GET / returns HTML with HTTP/3 200", async () => {
        const response = await get(`https://127.0.0.1:${server.port}/`);

        expect(response.status).toBe(200);
        expect(response.headers.get("content-type")).toContain("text/html");
        expect(response.headers.get("server")).toBe("zig-quiche-h3");

        // Check body contains expected content
        const body = new TextDecoder().decode(response.body);
        expect(body).toContain("Welcome to Zig QUIC/HTTP3 Server!");
        // (Content text may evolve; keep check stable to the welcome header only)
    });

    it("HEAD / returns headers without body", async () => {
        const response = await head(`https://127.0.0.1:${server.port}/`);

        expect(response.status).toBe(200);
        expect(response.headers.get("content-type")).toContain("text/html");

        // HEAD should have no body
        expect(response.body.length).toBe(0);
    });

    it("GET /api/users returns JSON array", async () => {
        const response = await get(`https://127.0.0.1:${server.port}/api/users`);

        expect(response.status).toBe(200);
        expect(response.headers.get("content-type")).toContain("application/json");
        expect(response.headers.get("content-type")).toContain("charset=utf-8");

        const json = JSON.parse(new TextDecoder().decode(response.body));
        expectJson(json, [] as Array<{ id: number; name: string }>);
        expect(Array.isArray(json)).toBe(true);

        // Validate content-length matches body size
        const contentLength = parseContentLength(response.headers);
        expect(contentLength).toBe(response.body.length);
    });

    it("GET /api/users/123 returns user with id=123", async () => {
        const response = await get(`https://127.0.0.1:${server.port}/api/users/123`);

        expect(response.status).toBe(200);
        expect(response.headers.get("content-type")).toContain("application/json");

        const json = JSON.parse(new TextDecoder().decode(response.body));
        expectJson(json, { id: "", name: "" }); // Type check - id is a string
        expect(json.id).toBe("123");
        expect(typeof json.name).toBe("string");
    });

    it("POST /api/users creates user (201)", async () => {
        const userData = JSON.stringify({ name: "Test User", email: "test@example.com" });
        const userBytes = new TextEncoder().encode(userData);

        const response = await post(`https://127.0.0.1:${server.port}/api/users`, userData, {
            headers: {
                "content-type": "application/json",
                "content-length": userBytes.length.toString(),
            },
        });

        expect(response.status).toBe(201);
        expect(response.headers.get("content-type")).toContain("application/json");

        const json = JSON.parse(new TextDecoder().decode(response.body));
        expect(json.message).toBe("User created");
        expect(json.received).toBe(userData);
    });

    it("POST /api/echo returns request body as JSON", async () => {
        const testData = { message: "Hello, HTTP/3!", timestamp: Date.now() };
        const body = JSON.stringify(testData);
        const bodyBytes = new TextEncoder().encode(body);

        const response = await post(`https://127.0.0.1:${server.port}/api/echo`, body, {
            headers: {
                "content-type": "application/json",
                "content-length": bodyBytes.length.toString(),
            },
        });

        expect(response.status).toBe(200);
        expect(response.headers.get("content-type")).toContain("application/json");

        const json = JSON.parse(new TextDecoder().decode(response.body));
        expect(json.received_bytes).toBe(JSON.stringify(testData).length);
        expect(json.content_type).toBe("application/json");
        expect(json.echo).toBe(JSON.stringify(testData));
    });

    it("GET /nonexistent returns 404", async () => {
        const response = await get(`https://127.0.0.1:${server.port}/nonexistent`);

        expect(response.status).toBe(404);
        expect(response.headers.get("content-length")).toBe("0");
        // Server sends only status and content-length: 0, no JSON body
        expect(response.body.length).toBe(0);
    });

    it("DELETE /api/users returns 405 with Allow header", async () => {
        const response = await zigClient(`https://127.0.0.1:${server.port}/api/users`, {
            method: "DELETE",
        });

        expect(response.status).toBe(405);

        const allowHeader = response.headers.get("allow");
        expect(allowHeader).toBeTruthy();

        // Should contain GET and POST (order may vary)
        expect(allowHeader).toContain("GET");
        expect(allowHeader).toContain("POST");
    });

    it("TLS validation fails without -k flag", async () => {
        // Test with a curl command that doesn't skip certificate validation
        await expect(
            zigClient(`https://127.0.0.1:${server.port}/`, {
                method: "GET",
                insecure: false,
                verifyPeer: true,
                curlCompat: false,
            }),
        ).rejects.toThrow();
    });

    it("Custom headers are handled correctly", async () => {
        const response = await get(`https://127.0.0.1:${server.port}/`, {
            headers: {
                "X-Test-Header": "test-value",
                "User-Agent": "zig-quiche-h3-tests/1.0",
            },
        });

        expect(response.status).toBe(200);

        // Server should handle custom headers without issues
        expect(response.headers.get("server")).toBe("zig-quiche-h3");
    });

    it("Large header values are handled", async () => {
        const largeValue = "x".repeat(1000); // 1KB header value

        const response = await get(`https://127.0.0.1:${server.port}/`, {
            headers: {
                "X-Large-Header": largeValue,
            },
        });

        // Should succeed with reasonable header sizes
        expect(response.status).toBe(200);
    });
});
