# HTTP/3 Range Requests — Design and Implementation Plan

This document captures a pragmatic, staged plan to add HTTP/1.1-style "Range: bytes=…" support to the zig-quiche-h3 server over HTTP/3. It specifies semantics, scope, API hooks, and tests so we can implement single‑range requests quickly and iterate toward full coverage.

## Summary
- v1 focuses on robust single-range support for files and known-size in-memory responses (e.g., `/download/*`, `/stream/test`).
- v2 adds multi-range (multipart/byteranges) and validators (If-Range with ETag / Last-Modified).
- v2b adds range support for generators/unknown-size streams (either by computing size or exposing a seekable generator API).

Why now: Resumable downloads and media scrubbing are table-stakes; many real clients assume working byte-ranges.

## Goals (v1)
- Support `Range: bytes=start-end`, `bytes=start-`, and `bytes=-suffix`.
- Return 206 Partial Content with correct `Content-Range` and `Content-Length` for satisfiable ranges.
- Return 416 Range Not Satisfiable with `Content-Range: bytes */size` when invalid/out of bounds.
- Add `Accept-Ranges: bytes` on range-capable responses.
- Work for GET and HEAD (HEAD returns only headers, must close stream with FIN).
- Cover two resource types:
  - File responses: `/download/*` (seek + bounded length read).
  - Known-size in-memory responses: `/stream/test` (slice the buffer).

## Non-goals (v1)
- Multi-range (comma-separated byte ranges) — defer; we’ll ignore and return 200 with full content (documented policy below).
- If-Range validator support (ETag / Last-Modified) — defer.
- Range over unknown-size generator streams (e.g., `/stream/1gb` generator) — defer unless we advertise a fixed size.

## Semantics and RFC Notes
- Range unit: Only `bytes` is supported. Any other unit → ignore Range (200) in v1.
- Single-range: `bytes=<start>-<end>` inclusive indices.
  - `bytes=500-999` → start=500, end=999.
  - `bytes=500-` → start=500, end=size-1.
  - `bytes=-500` → last 500 bytes → start=max(size-500, 0), end=size-1.
- Satisfiable vs unsatisfiable:
  - If start > end or start >= size → 416 with `Content-Range: bytes */<size>`.
  - Suffix larger than size → whole representation (start=0, end=size-1).
- Response headers:
  - Always add `Accept-Ranges: bytes` on range‑capable routes.
  - For 206: `Content-Range: bytes <start>-<end>/<size>`, `Content-Length: end-start+1`.
  - For HEAD: same headers as GET, no body; stream must be closed with FIN.
- Multiple ranges (contains comma): v1 policy — ignore and send 200 full content. We can switch to 206 multipart in v2.

## Parser API (v1)
A small parser isolates header logic; errors result in `error.InvalidRange` or a policy decision to ignore.

```zig
// bytes header → normalized inclusive offset range
pub const RangeSpec = struct {
    start: u64, // inclusive
    end: u64,   // inclusive, end >= start
};

/// Parse a single bytes range. Returns range in [0, size-1].
/// Errors with error.InvalidRange if unit != bytes, malformed syntax,
/// or start > end; caller can decide to ignore or 416.
pub fn parseRange(header: []const u8, size: u64) !RangeSpec;
```

Parsing rules:
- Trim ASCII whitespace; case-insensitive `bytes=` prefix.
- Reject if header contains `,` (multi-range) → return `error.MultiRange` so caller can choose policy (v1: ignore → 200).
- Handle open-ended and suffix forms; clamp to `[0, size-1]` with the suffix rule above.

Unit tests (v1) to include:
- `bytes=0-0`, `bytes=0-1023`, `bytes=1024-` (when size known), `bytes=-512`.
- Out of bounds → 416; malformed → ignore or 416 per call site policy.

## Server Integration (v1)

### Files (`/download/*`)
- Add `PartialResponse.initFileRange(allocator, file, start, end, buf_size, fin_on_complete)` or generalize `initFile` to accept an optional `(start, length)` pair.
- When `Range` present:
  - Parse with `parseRange` and `size = file.stat().size`.
  - On success → set status 206, headers (`Accept-Ranges`, `Content-Range`, `Content-Length`) and stream the bounded region (pread offset starts at `start`, stop at `end`).
  - On `error.InvalidRange` with `,` → v1 policy: IGNORE and return 200 full content.
  - On unsatisfiable → 416 with `Content-Range: bytes */size` and `Content-Length: 0`.
- Always add `Accept-Ranges: bytes` for `/download/*` responses.

### Known-size in-memory (`/stream/test`)
- `size = TEST_SIZE`. On Range:
  - Satisfiable: 206 + headers as above, then `writeAll(slice)` (or for HEAD, headers only).
  - Unsatisfiable: 416 + `Content-Range: bytes */size`.
- Add `Accept-Ranges: bytes`.

### HEAD behavior
- Ensure Response sends headers with FIN when `is_head_request` is true.
- For 206/416 HEAD, same header set, no body.

## Response/Streaming API Changes (v1)
- `src/http/streaming.zig`
  - Add `initFileRange(...)` or extend `initFile(...)` to accept optional `start`, `end` (inclusive) or `(start, length)`.
  - `getNextChunk()` must stop at `end` and set `is_final` when `offset > end`.
- `src/http/response.zig`
  - Provide a small helper to set range headers:
    - `setAcceptRangesBytes()` → header("accept-ranges", "bytes").
    - `setContentRange(start, end, size)` formats `Content-Range`.
  - HEAD semantics are critical: when `is_head_request`, don’t send body frames; send headers with FIN in `end()` or in code paths that short-circuit.

## Error Policy (v1)
- Unknown unit / malformed / multi-range:
  - Policy: ignore and return 200 OK full representation (documented), except clearly invalid numeric forms where we can safely 416.
  - Rationale: avoids surprising clients that send exploratory ranges while we don’t support multipart yet.
- Unsatisfiable range (start >= size or inverted range): 416 + `Content-Range: bytes */size`.

## Test Plan (Bun + curl)
- File ranges (`/download/*`):
  - bytes=0-1023 → 206; `content-length=1024`; `content-range=bytes 0-1023/<size>`; body length 1024.
  - bytes=1024- → 206; `content-length=size-1024`.
  - bytes=-512 → 206; `content-length=512`.
  - bytes=<size>- → 416; `content-range=bytes */<size>`; empty body.
  - HEAD + same ranges: 206/416 headers, `body.length == 0`.
  - Multi-range (contains comma): 200 full content (v1 policy); assert `accept-ranges: bytes` present.
- In-memory (`/stream/test`): replicate above with known size; verify `content-range` and body slice.
- Negative cases: malformed headers (`bytes=a-b`, `bytes=--`), unit mismatch (`items=0-1`) → 200 (ignore) or 416 per policy; document expectations.

Example assertion sketch:
```ts
const r = await curl(url(`/download/test.bin`), {
  headers: { Range: "bytes=0-1023" },
});
expect(r.status).toBe(206);
expect(r.headers.get("content-range")).toBe(`bytes 0-1023/${size}`);
expect(r.body.length).toBe(1024);
```

## Performance and Backpressure
- File ranges use `pread` and a bounded loop; no extra allocations beyond the existing buffer.
- `PartialResponse` backpressure (StreamBlocked) handling remains unchanged; we only cap total bytes and initial offset.
- Known-size memory slices reuse existing `writeAll()` with FIN on completion.

## Roadmap (v2+)
1) Multi-range support
- Detect comma in Range header; return `206` with `Content-Type: multipart/byteranges; boundary=…`.
- Build parts: for each range, emit `--boundary\r\nContent-Type: application/octet-stream\r\nContent-Range: bytes s-e/size\r\n\r\n<body>` … `--boundary--`.
- Consider `content-type` propagation from underlying resource when sensible.

2) Validators (If-Range)
- Add weak ETag (e.g., W/"<size>-<mtime>") or Last-Modified for file responses.
- If-Range handling: if validator matches → serve range; else ignore and serve 200 full content.

3) Generators / Unknown-size
- Add a seekable generator API: `generateFn(ctx, buf, offset) -> (n, done)` or a `skipTo(offset)` method.
- For known total size (e.g., 1GB demo), allow range if offset generation is cheap; otherwise return 200.

4) Observability
- Add debug logs for accepted/ignored ranges, and Prometheus-style counters (later).

## Open Questions / Decisions
- [ ] Multi-range v1 policy: ignore (200) vs reject (416). Current plan: ignore for compatibility.
- [ ] For malformed single-range (e.g., `bytes=--`), treat as ignore (200) or 416? Suggest: ignore unless we can definitively classify as unsatisfiable.
- [ ] `/stream/1gb` (generator) — advertise `Accept-Ranges: none` in v1, or omit header entirely on non-rangeable endpoints.

## Implementation Order (after stabilizing current tests)
1) HEAD + FIN correctness (already on the fix list).
2) Range parser + unit tests.
3) File range streaming + headers (206/416) + `Accept-Ranges`.
4) In-memory range slicing for `/stream/test` + headers.
5) Bun tests (GET + HEAD; satisfiable/unsatisfiable; suffix/open-ended).
6) Docs update (this file) → mark v1 done.

---

Appendix: Header Cheatsheet
- `Accept-Ranges: bytes`
- `Content-Range: bytes <start>-<end>/<size>` (206)
- `Content-Range: bytes */<size>` (416)
- `Content-Length: <length>` where `<length> = end - start + 1`

