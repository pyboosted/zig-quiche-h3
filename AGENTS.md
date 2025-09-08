# Repository Guidelines

## Project Structure & Module Organization
- `build.zig` — Zig build script; installs artifacts to `zig-out/bin/`.
- `src/` — main Zig code:
  - `net/` (event loop, UDP), `quic/` (config, connection, server), `ffi/` (quiche C FFI).
  - `examples/` — runnable demos: `udp_echo.zig`, `quic_server.zig`.
  - `main.zig` (smoke binary) and `tests.zig` (unit tests).
- `third_party/quiche/` — Git submodule (Cloudflare quiche). Do not edit; update via Git.
- `docs/` — design notes and plans.  `qlogs/` — QUIC qlog output.

## Build, Test, and Development Commands
- Init deps: `git submodule update --init --recursive`.
- Build quiche (default when not using system lib): `zig build quiche` or `zig build` (runs Cargo under the hood).
- Use system quiche: `zig build -Dsystem-quiche=true` (skip Cargo build).
- Common options: `-Dquiche-profile=release|debug`, `-Dwith-libev=true -Dlibev-include=… -Dlibev-lib=…`, `-Dlink-ssl=true`.
- Build binary: `zig build` → `zig-out/bin/zig-quiche-h3`.
- Run smoke app: `zig build run` (prints quiche version).
- Run examples:
  - UDP echo: `zig build echo` → send packets with `nc -u localhost 4433`.
  - QUIC server: `zig build quic-server -- --port 4433 --cert third_party/quiche/quiche/examples/cert.crt --key third_party/quiche/quiche/examples/cert.key`.
- Tests: `zig build test` or `zig test src/tests.zig`.

## Coding Style & Naming Conventions
- Run `zig fmt .` before commits. 4‑space indent, no tabs.
- Filenames: `snake_case.zig`. Types: `TitleCase`. Functions/vars: `lowerCamelCase`. Doc comments: `///`.
- Keep modules small (`src/net`, `src/quic`, `src/ffi`), avoid cyclic imports. Don’t modify `third_party/` sources.

## Testing Guidelines
- Add fast unit tests near code or in `src/tests.zig` using `test "…" {}`; name tests with short, imperative phrases.
- Integration: the QUIC server prints usage; validate with quiche client:
  `cd third_party/quiche && cargo run -p quiche --bin quiche-client -- https://127.0.0.1:4433/ --no-verify --alpn hq-interop`.

## Commit & Pull Request Guidelines
- Use Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `build:`, `chore:`). Keep subject ≤72 chars; add body for context.
- PRs must include: purpose, key changes, how to run/tests (`zig`/`cargo` commands), platform used, and relevant logs or `qlogs/` paths. Update docs if flags or behavior changed.

## Language Notes
- Zig version: use Zig 0.15.1 or later.
- C call convention: use `callconv(.c)` (lowercase `.c`), not `.C`.
- Zig 0.15 note: `std.ArrayList` is unmanaged; pass an allocator to operations (or use `std.ArrayListUnmanaged`).
