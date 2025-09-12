# Repository Guidelines

## Project Structure & Module Organization
- `build.zig` — Zig build script; installs to `zig-out/bin/`.
- `src/` — main code:
  - `net/` (event loop, UDP), `quic/` (config, connection, server), `ffi/` (quiche C FFI).
  - `examples/`: `udp_echo.zig`, `quic_server.zig`, `quic_dgram_echo.zig`.
  - `main.zig` (smoke binary), `tests.zig` (unit tests).
- `third_party/quiche/` — Cloudflare quiche submodule (do not edit).
- `docs/` — design notes; `qlogs/` — QUIC qlog output.

## Build, Test, and Development Commands
- Init deps: `git submodule update --init --recursive`.
- Build quiche (default when not using system lib): `zig build quiche` or simply `zig build` (runs Cargo for quiche).
- Use system quiche: `zig build -Dsystem-quiche=true`.
- Common flags: `-Dquiche-profile=release|debug`, `-Dwith-libev=true -Dlibev-include=… -Dlibev-lib=…`, `-Dlink-ssl=true`, `-Dwith-webtransport=false|true` (default: true).
- Build binary: `zig build` → `zig-out/bin/zig-quiche-h3`.
- Smoke app: `zig build run` (prints quiche version).
- Examples (require `-Dwith-libev=true`):
  - UDP echo: `zig build echo` → send with `nc -u localhost 4433`.
  - QUIC server: `zig build quic-server -- --port 4433 --cert third_party/quiche/quiche/examples/cert.crt --key third_party/quiche/quiche/examples/cert.key`.
- Tests: `zig build test` or `zig test src/tests.zig`.

## Coding Style & Naming Conventions
- Run `zig fmt .` before commits. 4‑space indent, no tabs.
- Filenames: `snake_case.zig`. Types: `TitleCase`. Functions/vars: `lowerCamelCase`. Use doc comments `///`.
- Keep modules small; avoid cyclic imports. Never modify `third_party/` sources.
- Zig 0.15.1+ required. Use `callconv(.c)` (lowercase `.c`). `std.ArrayList` is unmanaged in 0.15—pass an allocator (or use `std.ArrayListUnmanaged`).
- VS Code: Configure 4-space tabs for Zig files in `.vscode/settings.json`:
  ```json
  "[zig]": {
    "editor.tabSize": 4,
    "editor.insertSpaces": true,
    "editor.detectIndentation": false,
    "editor.formatOnSave": true
  }
  ```

## Testing Guidelines
- Unit tests live near code or in `src/tests.zig` using `test "…" {}`; name tests with short, imperative phrases.
- JS/TS E2E tests use Bun 1.x and live under `tests/e2e/`:
  - Run: `bun test tests/e2e`
  - Stress: `H3_STRESS=1 bun test`
  - Coverage: `bun test --coverage`
  - Note: curl helpers require HTTP/3 support; otherwise use the quiche client above.
- Manual: run the server, then from `third_party/quiche`: `cargo run -p quiche_apps --bin quiche-client -- https://127.0.0.1:4433/ --no-verify --alpn h3`.

## Commit & Pull Request Guidelines
- Use Conventional Commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `build:`, `chore:`. Keep subject ≤72 chars; add a body for context.
- PRs must include purpose, key changes, how to run/tests (`zig`/`cargo` commands), platform used, and relevant logs or `qlogs/` paths. Update docs if flags or behavior changed.

## Security & Configuration Tips
- Do not commit private keys; example certs live under `third_party/quiche/quiche/examples/`.
- Prefer release builds for performance: `-Dquiche-profile=release`. When linking system libs, set `-Dlink-ssl=true` and supply libev paths if used.

## Agent Tips (to build faster and safer)
- Init & build:
  - `git submodule update --init --recursive`
  - Prebuild quiche once: `zig build quiche -Dquiche-profile=release`
  - Use system quiche when available: `-Dsystem-quiche=true`
  - Link libev for server/examples: `-Dwith-libev=true -Dlibev-include=… -Dlibev-lib=…`
- Common run targets:
  - Smoke: `zig build run`
  - QUIC server: `zig build quic-server -- --port 4433 --cert … --key …`
  - QUIC dgram echo: `zig build quic-dgram-echo -- --port 4433 --cert … --key …`
- Coding surfaces to prefer:
  - `Response` API: `status/header/write/writeAll/end/sendTrailers` (not the deprecated sendHead/sendBody docs pattern).
  - H3 DATAGRAM: `router.routeH3Datagram()` and `Response.sendH3Datagram()`; QUIC DATAGRAM via `QuicServer.onDatagram()` and `sendDatagram()`.
  - WebTransport: compiled in by default; use `H3_WEBTRANSPORT=1` at runtime. WT shims live under `src/quic/server/webtransport.zig`.
  - Don’t touch `third_party/`.
- Housekeeping:
  - Run `zig fmt .` before proposing patches.
  - Keep links canonical (no tracking params) in docs.
  - Use `rg` for fast code/search and read files in ≤250‑line chunks when tooling limits apply.
