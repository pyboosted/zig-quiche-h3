#!/usr/bin/env bun

import * as fs from "node:fs/promises";
// HTTPS server that sets Alt-Svc pointing to the zig HTTP/3 server and
// optionally spawns that zig server on a separate port. Serves index.html and
// TypeScript client with Bun's built-in transpilation.
import { join, normalize } from "path";

type Opts = {
    port: number; // HTTPS shim port
    h3Port: number; // QUIC server port
    certPath: string;
    keyPath: string;
    certStatus: "provided" | "mkcert" | "openssl" | "existing" | "unknown";
    host: string;
    altHost: string | null; // optional: explicit host for Alt-Svc authority (e.g., 127.0.0.1)
    maxAge: number;
    persist: boolean;
    spawn: boolean;
    optimize: string;
};

async function parseArgs(): Promise<Opts> {
    const argv = process.argv.slice(2);
    const get = (flag: string, dflt?: string): string | undefined => {
        const i = argv.indexOf(flag);
        if (i !== -1 && argv[i + 1]) return argv[i + 1];
        return dflt;
    };
    const has = (flag: string): boolean => argv.includes(flag);

    const repoRoot = await findRepoRoot();
    const port = Number(get("--port", "8443"));
    const h3Port = Number(get("--h3-port", "4444"));
    // Default certs live under the example directory to avoid touching third_party
    const exampleDir = join(repoRoot, "examples/bun-http3-wrapper");
    const defaultCert = join(exampleDir, "certs/localhost.pem");
    const defaultKey = join(exampleDir, "certs/localhost-key.pem");
    let certPath = get("--cert", defaultCert)!;
    let keyPath = get("--key", defaultKey)!;
    let certStatus: Opts["certStatus"] = get("--cert") || get("--key") ? "provided" : "unknown";
    const host = get("--host", "localhost")!;
    const maxAge = Number(get("--ma", "86400"));
    // Allow overriding the Alt-Svc authority host to force IPv4 (helps avoid ::1 path issues in some setups)
    // Default: if host is "localhost", prefer 127.0.0.1 for the Alt-Svc mapping; otherwise use same-host (":" syntax)
    const altHostFlag = get("--alt-host");
    const altHost = altHostFlag ? altHostFlag : host === "localhost" ? "127.0.0.1" : null;
    const persist = !has("--no-persist");
    const spawn = !has("--no-spawn");
    const optimize = get("--opt", "ReleaseFast")!;
    // If user did not override cert/key and the defaults do not exist, try to generate them.
    if (!get("--cert") && !get("--key")) {
        const ensured = await ensureLocalhostCerts(repoRoot, certPath, keyPath);
        certPath = ensured.cert;
        keyPath = ensured.key;
        certStatus = ensured.status;
    }
    return {
        port,
        h3Port,
        certPath,
        keyPath,
        certStatus,
        host,
        altHost,
        maxAge,
        persist,
        spawn,
        optimize,
    };
}

const opts = await parseArgs();
// Advertise HTTP/3 on the QUIC port; include h3-29 for older clients.
// If opts.altHost is set (or defaulted to 127.0.0.1 when host==localhost), use explicit authority to force IPv4.
const altAuthority = opts.altHost ? `${opts.altHost}:${opts.h3Port}` : `:${opts.h3Port}`;
const ALT_SVC_VALUE = `h3="${altAuthority}"; ma=${opts.maxAge}; persist=0`;

// (TLS material used below by Bun.serve HTTPS server)

const decoder = new TextDecoder();

function appLog(msg: string) {
    console.log(msg);
}

function attachAltSvc(resp: Response): Response {
    const headers = new Headers(resp.headers);
    headers.set("Alt-Svc", ALT_SVC_VALUE);
    headers.set("Cache-Control", "no-store");
    return new Response(resp.body, { status: resp.status, headers });
}

const _projectRoot = join(import.meta.dir, "../..");
const entryHtml = join(import.meta.dir, "../index.html");

// Build the client bundle in-memory via Bun.build so the browser can import TS.
// We serve BuildArtifacts from memory and add Alt-Svc on every response.
const buildResult = await Bun.build({
    entrypoints: [entryHtml],
    // in-memory outputs; no outdir needed for dev wrapper
    sourcemap: "inline",
});

if (!buildResult.success) {
    console.error("Bun.build failed:");
    for (const m of buildResult.logs) console.error(m);
    process.exit(1);
}

const artifacts = new Map<string, Blob>();
let indexPath: string | null = null;
for (const out of buildResult.outputs) {
    // Normalize output path to "/..."
    // Paths from build are typically like "./index-[hash].js" or "./index.html"
    const clean = `/${out.path.replace(/^\.\//, "")}`;
    artifacts.set(clean, out);
    if (clean.endsWith(".html")) indexPath = clean;
}
if (!indexPath) indexPath = "/index.html"; // fallback

// Precompute artifact buffers + content-type for HTTP/2
type Artifact = { body: Uint8Array; contentType: string };
const artifactsBuf = new Map<string, Artifact>();
function contentTypeFor(pathname: string): string {
    if (pathname.endsWith(".html")) return "text/html; charset=utf-8";
    if (pathname.endsWith(".js")) return "text/javascript; charset=utf-8";
    if (pathname.endsWith(".css")) return "text/css; charset=utf-8";
    if (pathname.endsWith(".json")) return "application/json; charset=utf-8";
    if (pathname.endsWith(".svg")) return "image/svg+xml";
    if (pathname.endsWith(".png")) return "image/png";
    if (pathname.endsWith(".jpg") || pathname.endsWith(".jpeg")) return "image/jpeg";
    return "application/octet-stream";
}
for (const [p, blob] of artifacts) {
    const ab = await blob.arrayBuffer();
    artifactsBuf.set(p, { body: new Uint8Array(ab), contentType: contentTypeFor(p) });
}

let server: ReturnType<typeof Bun.serve> | null = null;
{
    // Plain Bun.serve HTTPS (HTTP/1.1), no h2. Useful to test privileged ports.
    // Keep Alt-Svc pointing at the QUIC server port so browsers learn about h3.
    const keyFile = Bun.file(opts.keyPath);
    const certFile = Bun.file(opts.certPath);

    server = Bun.serve({
        hostname: opts.host,
        port: opts.port,
        tls: {
            key: keyFile,
            cert: certFile,
        },
        fetch(req) {
            const url = new URL(req.url);
            const pathname = url.pathname;

            // No SSE log streaming endpoint; logs are printed to terminal.

            if (pathname === "/cert-status") {
                return attachAltSvc(
                    new Response(
                        JSON.stringify({
                            status: opts.certStatus,
                            certPath: opts.certPath,
                            keyPath: opts.keyPath,
                        }),
                        { headers: { "content-type": "application/json; charset=utf-8" } },
                    ),
                );
            }
            if (pathname === "/healthz") {
                return attachAltSvc(
                    new Response("ok", {
                        headers: { "content-type": "text/plain; charset=utf-8" },
                    }),
                );
            }

            if (pathname === "/" || pathname === "/index.html") {
                const art = artifactsBuf.get(indexPath!);
                if (!art) return attachAltSvc(new Response("Missing index.html", { status: 500 }));
                return attachAltSvc(
                    new Response(art.body as BodyInit, { headers: { "content-type": art.contentType } }),
                );
            }

            const art = artifactsBuf.get(pathname);
            if (art) {
                appLog(`[http1] serving asset ${pathname}`);
                return attachAltSvc(
                    new Response(art.body as BodyInit, { headers: { "content-type": art.contentType } }),
                );
            }

            appLog(`[http1] 404 ${pathname}`);
            return attachAltSvc(new Response("Not Found", { status: 404 }));
        },
    });
    appLog(`Alt-Svc wrapper (Bun.serve HTTP/1.1) listening: https://${opts.host}:${opts.port}`);
    // For visibility; Bun doesn't expose ALPN (HTTP/1.1 only here)
}

appLog(`Advertising: Alt-Svc: ${ALT_SVC_VALUE}`);
appLog(`TLS cert: ${opts.certPath}`);
appLog(`TLS key : ${opts.keyPath}`);
appLog(`[cert] status: ${opts.certStatus}`);

// ---------------- Spawn zig quic-server (optional) ----------------

async function findRepoRoot(): Promise<string> {
    // Walk up from current file's directory until build.zig is found
    let path = import.meta.dir;
    for (let i = 0; i < 8; i++) {
        const probe = Bun.file(join(path, "build.zig"));
        if (await probe.exists()) return path;
        path = normalize(join(path, ".."));
    }
    // Fallback: two levels up from this file (examples/bun-http3-wrapper/src -> repo root)
    return normalize(join(import.meta.dir, "../.."));
}

async function ensureQuicServerBuilt(repoRoot: string) {
    const bin = join(repoRoot, "zig-out/bin/quic-server");
    try {
        const p = Bun.spawn({ cmd: [bin, "--help"], stdout: "ignore", stderr: "ignore" });
        await p.exited;
        if (p.exitCode === 0) return bin;
    } catch {}

    appLog("Building quic-server (zig build)…");
    const args = ["zig", "build", "-Dwith-libev=true", `-Doptimize=${opts.optimize}`];
    const inc =
        process.env.H3_LIBEV_INCLUDE ??
        (process.platform === "darwin" ? "/opt/homebrew/opt/libev/include" : undefined);
    const lib =
        process.env.H3_LIBEV_LIB ??
        (process.platform === "darwin" ? "/opt/homebrew/opt/libev/lib" : undefined);
    if (inc) args.push(`-Dlibev-include=${inc}`);
    if (lib) args.push(`-Dlibev-lib=${lib}`);
    const b = Bun.spawn({ cmd: args, cwd: repoRoot, stdout: "inherit", stderr: "inherit" });
    const code = await b.exited;
    if (code !== 0) throw new Error("zig build failed");
    return bin;
}

let child: ReturnType<typeof Bun.spawn> | null = null;

async function spawnQuicServer() {
    try {
        const root = await findRepoRoot();
        const bin = await ensureQuicServerBuilt(root);
        const args = [
            bin,
            "--port",
            String(opts.h3Port),
            "--cert",
            opts.certPath,
            "--key",
            opts.keyPath,
            "--no-qlog",
        ];
        appLog(`[spawn] ${args.join(" ")}`);
        child = Bun.spawn({ cmd: args, cwd: root, stdout: "pipe", stderr: "pipe" });
        if (child.stdout && typeof child.stdout !== "number")
            void streamLines(child.stdout as ReadableStream<Uint8Array>, "quic-server");
        if (child.stderr && typeof child.stderr !== "number")
            void streamLines(child.stderr as ReadableStream<Uint8Array>, "quic-server");
        child.exited.then((code) => appLog(`[quic-server] exited with code ${code}`));
        await Bun.sleep(300);
    } catch (e) {
        appLog(`Failed to spawn quic-server: ${e}`);
    }
}

if (opts.spawn) void spawnQuicServer();

async function gracefulShutdown() {
    try {
        if (server) {
            appLog("[shutdown] stopping HTTP server");
            server.stop();
        }
    } catch {}

    if (child && !child.killed) {
        try {
            appLog("[shutdown] killing quic-server child");
            child.kill();
            await child.exited;
        } catch {}
    }
    appLog("[shutdown] done");
    process.exit(0);
}

process.on("SIGINT", () => void gracefulShutdown());
process.on("SIGTERM", () => void gracefulShutdown());

// ---------------- Certificates (mkcert or openssl fallback) ----------------

async function pathExists(p: string): Promise<boolean> {
    try {
        const st = await fs.stat(p);
        return st.isFile();
    } catch {
        return false;
    }
}

async function ensureLocalhostCerts(
    repoRoot: string,
    certPath: string,
    keyPath: string,
): Promise<{ cert: string; key: string; status: "mkcert" | "openssl" | "existing" | "unknown" }> {
    const certExists = await pathExists(certPath);
    const keyExists = await pathExists(keyPath);
    if (certExists && keyExists) return { cert: certPath, key: keyPath, status: "existing" };

    // Make sure the certs directory exists
    const dir = normalize(join(certPath, ".."));
    await fs.mkdir(dir, { recursive: true }).catch(() => {});

    // Try mkcert first (trusted dev certs)
    let mkcertOk = false;
    try {
        const version = Bun.spawn({
            cmd: ["mkcert", "-version"],
            stdout: "ignore",
            stderr: "ignore",
        });
        const code = await version.exited;
        if (code === 0) {
            // Ensure local CA is installed (may prompt on first run)
            appLog("[cert] mkcert detected; ensuring local CA is installed");
            await Bun.spawn({ cmd: ["mkcert", "-install"], stdout: "pipe", stderr: "pipe" }).exited;
            const gen = Bun.spawn({
                cmd: [
                    "mkcert",
                    "-key-file",
                    keyPath,
                    "-cert-file",
                    certPath,
                    "localhost",
                    "127.0.0.1",
                    "::1",
                ],
                cwd: repoRoot,
                stdout: "pipe",
                stderr: "pipe",
            });
            if (gen.stdout && typeof gen.stdout !== "number")
                void streamLines(gen.stdout as ReadableStream<Uint8Array>, "mkcert");
            if (gen.stderr && typeof gen.stderr !== "number")
                void streamLines(gen.stderr as ReadableStream<Uint8Array>, "mkcert");
            const genCode = await gen.exited;
            mkcertOk = genCode === 0;
            if (mkcertOk) {
                appLog(`[cert] Generated mkcert dev certs at ${dir}`);
                return { cert: certPath, key: keyPath, status: "mkcert" };
            }
        }
    } catch {}

    // Fallback: self-signed via openssl with SANs (not trusted automatically)
    try {
        const cnf = join(dir, "openssl.cnf");
        const cnfContent = `
[ req ]
default_bits       = 2048
distinguished_name = req_distinguished_name
req_extensions     = v3_req
prompt             = no

[ req_distinguished_name ]
CN = localhost

[ v3_req ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = localhost
IP.1 = 127.0.0.1
IP.2 = ::1
`;
        await fs.writeFile(cnf, cnfContent);
        const gen = Bun.spawn({
            cmd: [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-sha256",
                "-days",
                "3650",
                "-nodes",
                "-subj",
                "/CN=localhost",
                "-keyout",
                keyPath,
                "-out",
                certPath,
                "-config",
                cnf,
                "-extensions",
                "v3_req",
            ],
            cwd: repoRoot,
            stdout: "pipe",
            stderr: "pipe",
        });
        if (gen.stdout && typeof gen.stdout !== "number")
            void streamLines(gen.stdout as ReadableStream<Uint8Array>, "openssl");
        if (gen.stderr && typeof gen.stderr !== "number")
            void streamLines(gen.stderr as ReadableStream<Uint8Array>, "openssl");
        const code = await gen.exited;
        if (code === 0) {
            appLog(
                "[cert] Generated self-signed certs with SANs (not trusted). For Chrome, prefer mkcert.",
            );
            return { cert: certPath, key: keyPath, status: "openssl" };
        }
    } catch (e) {
        appLog(`[cert] Failed to generate certs: ${e}`);
    }

    appLog(
        "[cert] Using defaults but could not generate certs. Browsers may reject the connection.",
    );
    return { cert: certPath, key: keyPath, status: "unknown" };
}

async function streamLines(stream: ReadableStream<Uint8Array>, tag: string) {
    let buf = "";
    const reader = stream.getReader();
    try {
        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            if (value) {
                buf += decoder.decode(value, { stream: true });
                let idx: number = buf.indexOf("\n");
                while (idx !== -1) {
                    const line = buf.slice(0, idx).replace(/\r$/, "");
                    if (line) appLog(`[${tag}] ${line}`);
                    buf = buf.slice(idx + 1);
                    idx = buf.indexOf("\n");
                }
            }
        }
    } catch (e) {
        appLog(`[${tag}] stream error: ${e}`);
    } finally {
        reader.releaseLock();
    }
    if (buf.length) appLog(`[${tag}] ${buf}`);
}
