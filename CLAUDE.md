# Repository Guidelines

## Project Structure & Module Organization
- `build.zig` — Zig build script; installs to `zig-out/bin/`.
- `src/` — main code:
  - `net/` (event loop, UDP), `quic/` (config, connection, server), `ffi/` (quiche C FFI).
  - `examples/`: `udp_echo.zig`, `quic_server.zig`.
  - `main.zig` (smoke binary), `tests.zig` (unit tests).
- `third_party/quiche/` — Cloudflare quiche submodule (do not edit).
- `docs/` — design notes; `qlogs/` — QUIC qlog output.

## Build, Test, and Development Commands
- Init deps: `git submodule update --init --recursive`.
- Build quiche (default when not using system lib): `zig build quiche` or simply `zig build` (runs Cargo for quiche).
- Use system quiche: `zig build -Dsystem-quiche=true`.
- Common flags: `-Dquiche-profile=release|debug`, `-Dwith-libev=true -Dlibev-include=… -Dlibev-lib=…`, `-Dlink-ssl=true`.
- Build binary: `zig build` → `zig-out/bin/zig-quiche-h3`.
- Smoke app: `zig build run` (prints quiche version).
- Examples:
  - UDP echo: `zig build echo` → send with `nc -u localhost 4433`.
  - QUIC server: `zig build quic-server -- --port 4433 --cert third_party/quiche/quiche/examples/cert.crt --key third_party/quiche/quiche/examples/cert.key`.
- Tests: `zig build test` or `zig test src/tests.zig`.

## Coding Style & Naming Conventions
- Run `zig fmt .` before commits. 4‑space indent, no tabs.
- Filenames: `snake_case.zig`. Types: `TitleCase`. Functions/vars: `lowerCamelCase`. Use doc comments `///`.
- Keep modules small; avoid cyclic imports. Never modify `third_party/` sources.
- Zig 0.15.1+ required. Use `callconv(.c)` (lowercase `.c`). `std.ArrayList` is unmanaged in 0.15—pass an allocator (or use `std.ArrayListUnmanaged`).

## Testing Guidelines
- Unit tests live near code or in `src/tests.zig` using `test "…" {}`; name tests with short, imperative phrases.
- Integration: run the server, then from `third_party/quiche`: `cargo run -p quiche --bin quiche-client -- https://127.0.0.1:4433/ --no-verify --alpn hq-interop`.
 - JS/TS tests (if present) use Bun 1.x: setup `bun install`; run `bun test`; coverage with `bun test --coverage`. Place tests as `*.test.ts` under `scripts/` or `tests/js/`.

## Commit & Pull Request Guidelines
- Use Conventional Commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `build:`, `chore:`. Keep subject ≤72 chars; add a body for context.
- PRs must include purpose, key changes, how to run/tests (`zig`/`cargo` commands), platform used, and relevant logs or `qlogs/` paths. Update docs if flags or behavior changed.

## Security & Configuration Tips
- Do not commit private keys; example certs live under `third_party/quiche/quiche/examples/`.
- Prefer release builds for performance: `-Dquiche-profile=release`. When linking system libs, set `-Dlink-ssl=true` and supply libev paths if used.
