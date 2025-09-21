4 tests failed:
✗ Per-connection download cap [static] > rejects second concurrent file download with 503 when cap=1 [5001.04ms]
✗ Per-connection download cap [dynamic] > rejects second concurrent file download with 503 when cap=1 [5000.13ms]
✗ Per-connection request cap [static] > rejects N+1 requests with 503 on same connection > third concurrent request gets 503 when cap=2 [4520.30ms]
✗ Per-connection request cap [dynamic] > rejects N+1 requests with 503 on same connection > third concurrent request gets 503 when cap=2 [4534.69ms]

Fixed:
✓ HTTP/3 Range Requests - "ignores multi-range requests and returns full file" (both static and dynamic) - fixed by changing header separator from comma to newline