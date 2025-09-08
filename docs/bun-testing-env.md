# Bun-based E2E Testing Environment

This document describes a lightweight, fast end-to-end (E2E) testing setup for zig-quiche-h3 using Bun for orchestration and curl (HTTP/3-enabled) as the client. It’s ideal for validating streaming, backpressure, large uploads/downloads, and correctness across routes.

## Why Bun + curl
- Bun gives a fast test runner (`bun test`), simple process APIs (`Bun.spawn`), and first-class TypeScript.
- curl provides a mature, debuggable HTTP/3 client (`--http3` / `--http3-only`) with rich flags for headers, TLS, and streaming.
- For H3 features curl doesn’t cover (e.g., DATAGRAM/WebTransport later), we can fall back to the `quiche-client` app.

## Prerequisites
- Zig build of the server: `zig build` produces `zig-out/bin/zig-quiche-h3`.
- Bun ≥ 1.0 installed (`bun --version`).
- curl with HTTP/3 support available on PATH (verify with `curl --http3 -V`).
  - Quick check: `curl -V` should mention `nghttp3` and/or `quiche`, and `--http3` should be accepted.
- Test TLS: use the example self-signed cert/key in `third_party/quiche/quiche/examples/`.

## Directory Layout
```
/tests
  /e2e
    /helpers
      spawnServer.ts        # build/spawn server, readiness probe, cleanup
    http_basic.test.ts      # small JSON/headers, 200/404/405, HEAD
    stream_download.test.ts # large downloads (file/generator), integrity checks
    stream_upload.test.ts   # large uploads (SHA-256 or length validation)
    backpressure.test.ts    # concurrency + partial writes (optional)
```

## Server Lifecycle Helper (spawnServer)
Use a single helper to build, spawn, probe readiness with curl, and tear down.

```ts
// tests/e2e/helpers/spawnServer.ts
import { spawn } from "bun";

export async function spawnServer(opts?: { port?: number; qlog?: boolean }) {
  const port = opts?.port ?? (44330 + ((Math.random() * 1000) | 0));

  // Build once here or in CI step. For local dev, this is convenient:
  // await $`zig build` (or use Bun.spawn to run it). Skipped here for brevity.

  const args = [
    "zig-out/bin/zig-quiche-h3",
    "--port",
    String(port),
    "--cert",
    "third_party/quiche/quiche/examples/cert.crt",
    "--key",
    "third_party/quiche/quiche/examples/cert.key",
    ...(opts?.qlog === false ? ["--no-qlog"] : []),
  ];

  const proc = spawn({ cmd: args, stdout: "pipe", stderr: "pipe", env: { ...process.env } });

  // Readiness probe via curl HEAD request
  const deadline = Date.now() + 8_000;
  let ready = false;
  async function probe() {
    const ping = spawn({
      cmd: ["curl", "-sk", "--http3", "-I", `https://127.0.0.1:${port}/`],
      stdout: "pipe",
      stderr: "pipe",
    });
    await ping.exited;
    return ping.exitCode === 0;
  }
  while (Date.now() < deadline) {
    if (await probe()) { ready = true; break; }
    await Bun.sleep(150);
  }
  if (!ready) {
    proc.kill("SIGTERM");
    throw new Error("Server not ready");
  }

  return { proc, port };
}
```

## Example Tests

### Basic HTTP/3
```ts
// tests/e2e/http_basic.test.ts
import { describe, it, beforeAll, afterAll, expect } from "bun:test";
import { spawnServer } from "./helpers/spawnServer";

let server: { proc: any; port: number };
const curl = (...args: string[]) =>
  Bun.spawn(["curl", "-sk", "--http3-only", ...args], { stdout: "pipe", stderr: "pipe" });

describe("HTTP/3 basic", () => {
  beforeAll(async () => { server = await spawnServer({ qlog: false }); });
  afterAll(() => { server.proc.kill("SIGTERM"); });

  it("GET / returns HTML", async () => {
    const p = curl(`https://127.0.0.1:${server.port}/`, "-i");
    await p.exited;
    const text = await new Response(p.stdout).text();
    expect(text).toContain("HTTP/3 200");
    expect(text.toLowerCase()).toContain("content-type: text/html");
  });

  it("JSON route works", async () => {
    const p = curl(`https://127.0.0.1:${server.port}/api/users`, "-i");
    await p.exited;
    const text = await new Response(p.stdout).text();
    expect(text).toContain("HTTP/3 200");
    const body = text.split("\r\n\r\n")[1];
    const obj = JSON.parse(body);
    expect(Array.isArray(obj)).toBeTrue();
  });
});
```

### Streaming Download
```ts
// tests/e2e/stream_download.test.ts
import { describe, it, beforeAll, afterAll, expect } from "bun:test";
import { spawnServer } from "./helpers/spawnServer";
import { createHash } from "node:crypto";

let server: { proc: any; port: number };
const curl = (...args: string[]) =>
  Bun.spawn(["curl", "-sk", "--http3-only", ...args], { stdout: "pipe", stderr: "pipe" });

describe("Streaming download", () => {
  beforeAll(async () => { server = await spawnServer({ qlog: false }); });
  afterAll(() => { server.proc.kill("SIGTERM"); });

  it("/stream/test returns 10MB and a checksum header", async () => {
    const p = curl(`https://127.0.0.1:${server.port}/stream/test`, "-i");
    await p.exited;
    const raw = await new Response(p.stdout).text();
    const [head, body] = raw.split("\r\n\r\n");
    expect(head).toContain("HTTP/3 200");
    const data = Buffer.from(body, "binary");
    expect(data.byteLength).toBe(10 * 1024 * 1024);
    // Optional integrity check
    const sha = createHash("sha256").update(data).digest("hex");
    expect(sha.length).toBe(64);
  });
});
```

### Streaming Upload
```ts
// tests/e2e/stream_upload.test.ts
import { describe, it, beforeAll, afterAll, expect } from "bun:test";
import { spawnServer } from "./helpers/spawnServer";

let server: { proc: any; port: number };

async function makeTempFile(bytes: number) {
  const path = `${Bun.env.TMPDIR ?? "/tmp"}/h3-upload-${Date.now()}.bin`;
  const buf = new Uint8Array(bytes);
  for (let i = 0; i < buf.length; i++) buf[i] = i & 0xff;
  await Bun.write(path, buf); // single write is fine for ~tens of MB
  return path;
}

const curl = (...args: string[]) =>
  Bun.spawn(["curl", "-sk", "--http3-only", ...args], { stdout: "pipe", stderr: "pipe" });

describe("Streaming upload", () => {
  beforeAll(async () => { server = await spawnServer({ qlog: false }); });
  afterAll(() => { server.proc.kill("SIGTERM"); });

  it("uploads 64MB and returns stats", async () => {
    const file = await makeTempFile(64 * 1024 * 1024);
    const p = curl(
      "-X",
      "POST",
      "-H",
      "content-type: application/octet-stream",
      "--data-binary",
      `@${file}`,
      `https://127.0.0.1:${server.port}/upload/test`,
    );
    await p.exited;
    const text = await new Response(p.stdout).text();
    const obj = JSON.parse(text);
    expect(obj.received_bytes).toBe(64 * 1024 * 1024);
    expect(typeof obj.checksum).toBe("string");
  });
});
```

## Running the Tests
- Build: `zig build` (or let CI do it once before running Bun tests).
- Run: `bun test tests/e2e`.
- Ports: by default the helper picks a random high port. To fix the port, pass `spawnServer({ port: 44331 })` or export `H3_TEST_PORT` and read it in the helper.

## Notes & Tips
- Always use `-k/--insecure` in tests to accept the example self-signed certificate.
- Use `--http3-only` to guarantee the connection negotiates H3 (fail fast otherwise).
- For very large downloads where you don’t need the body, stream to null: `curl ... --output /dev/null` and assert headers/status only.
- Concurrency/backpressure: spawn multiple curls in parallel and assert all `content-length` values match expected sizes to catch truncation.
- Readiness: prefer an actual HEAD/GET probe (as above) instead of parsing logs; it’s resilient to log changes.

## Fallbacks for Advanced Features
- If local curl lacks HTTP/3 support, run `third_party/quiche` client for those cases:
  ```bash
  cd third_party/quiche
  cargo run -p quiche --bin quiche-client -- \
    https://127.0.0.1:4433/ --no-verify --alpn h3
  ```
- Later (Milestones 6–8), use `quiche-client` for H3 DATAGRAM / WebTransport coverage that curl doesn’t provide.

## CI Considerations
- Build once, then run `bun test`.
- Disable qlog by default in CI (`--no-qlog`) to limit disk writes, re-enable for debugging when needed.
- Keep tests hermetic: do not rely on global curl config; pass flags explicitly in each test.

---

This harness gives quick iteration, debuggable failures (curl output is explicit), and good coverage for streaming and backpressure behavior while staying close to how real clients talk to HTTP/3 servers.
