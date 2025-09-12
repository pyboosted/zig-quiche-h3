const logEl = document.getElementById("log")!;

function log(msg: string, cls?: string) {
    const div = document.createElement("div");
    div.textContent = msg;
    if (cls) div.className = cls;
    logEl.appendChild(div);
}

function qs<T extends HTMLElement>(sel: string): T {
    const el = document.querySelector(sel);
    if (!el) throw new Error(`Missing element: ${sel}`);
    return el as T;
}

log(`Origin: ${location.origin}`);
log(`Tip: In DevTools → Network, add the Protocol column to verify h3 after reload.`);

// Logs are shown in the server terminal; no SSE in this setup.

qs<HTMLButtonElement>("#btnFetch").onclick = async () => {
    try {
        const res = await fetch("/");
        log(`GET / → ${res.status} ${res.headers.get("content-type") || ""}`, "ok");
        const text = await res.text();
        log(text.slice(0, 1600) + (text.length > 1600 ? "…" : ""));
    } catch (e) {
        log(`Fetch error: ${e}`, "err");
    }
};

qs<HTMLButtonElement>("#btnCustom").onclick = async () => {
    const path = qs<HTMLInputElement>("#path").value;
    try {
        const res = await fetch(path);
        log(`GET ${path} → ${res.status}`, "ok");
        const text = await res.text();
        log(text.slice(0, 1600) + (text.length > 1600 ? "…" : ""));
    } catch (e) {
        log(`Fetch error: ${e}`, "err");
    }
};
