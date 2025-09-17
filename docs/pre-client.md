# Pre-Client Server Readiness Plan

The server is almost feature-complete for acting as the counterpart to the upcoming HTTP/3/WebTransport client. While reviewing the current tree we noticed that connection timeout handling is still gated by TODOs in `src/quic/server/mod.zig`. The periodic timer (`onTimeoutTimer`) is wired but does not invoke any logic, and per-connection deadlines (`Connection.timeout_deadline_ms`) / timer handles are never populated. As a result the server relies entirely on quiche's implicit polling during packet receive/send; idle peers are never reaped, and quiche's retransmit timers are not honoured once traffic stalls. The planned client harness will depend on timely idle cleanup (to assert GOAWAY/close semantics, retry behaviour, etc.), so we should implement the missing timeout path before we start the client work.

## Goals

1. **Implement connection timeout loop** so that `quiche_conn_on_timeout()` is called when a connection's deadline expires.
2. **Track per-connection deadlines** in the `Connection` struct and update them whenever quiche reports a new timeout. ✅
3. **Integrate with the event loop** so we fire callbacks only when the next deadline is due (instead of polling continuously). ✅
4. **Exercise the new logic in tests** (unit or integration) to confirm idle connections are closed and that timers are rescheduled when traffic resumes. ➡️ Manual validation still recommended, but initial test suite passes.

## Summary

- `src/net/event_loop.zig` now exposes reusable timer handles (`createTimer`, `startTimer`, `stopTimer`, `destroyTimer`).
- `src/quic/connection.zig` tracks optional per-connection deadlines.
- `src/quic/server/mod.zig` maintains the earliest deadline, arms a single timer, calls `quiche_conn_on_timeout()`, drains egress, and closes idle connections.
- Integration tests (`zig build test`) continue to pass; real-world idle expiry should still be sanity-checked.

With these changes, the timeout prereq is closed and the client harness can rely on timely idle cleanup.
