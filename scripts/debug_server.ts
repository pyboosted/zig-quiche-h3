import { createH3Server } from "../src/bun/server.ts";
import { zigClient } from "../tests/e2e/helpers/zigClient.ts";
import { getCertPath, randPort } from "../tests/e2e/helpers/testUtils.ts";

const port = randPort();
const server = createH3Server({
  hostname: "127.0.0.1",
  port,
  certPath: getCertPath("cert.crt"),
  keyPath: getCertPath("cert.key"),
  enableDatagram: true,
  fetch: async (req) => {
    console.log("fetch called", req.url);
    return new Response("ok", { status: 200 });
  },
});

await Bun.sleep(100);

try {
  const res = await zigClient(`https://127.0.0.1:${port}/`, {
    insecure: true,
    outputBody: true,
  });
  const text = new TextDecoder().decode(res.body ?? new Uint8Array());
  console.log("status", res.status, "body", text);
} finally {
  server.close();
}
