# Pre-Client Server Readiness Plan

The server is almost feature-complete for acting as the counterpart to the upcoming HTTP/3/WebTransport client. While reviewing the current tree we noticed that connection timeout handling is still gated by TODOs in `src/quic/server/mod.zig`. The periodic timer (`onTimeoutTimer`) is wired but does not invoke any logic, and per-connection deadlines (`Connection.timeout_deadline_ms`) / timer handles are never populated. As a result the server relies entirely on quiche's implicit polling during packet receive/send; idle peers are never reaped, and quiche's retransmit timers are not honoured once traffic stalls. The planned client harness will depend on timely idle cleanup (to assert GOAWAY/close semantics, retry behaviour, etc.), so we should implement the missing timeout path before we start the client work.

## Goals

1. **Implement connection timeout loop** so that `quiche_conn_on_timeout()` is called when a connection's deadline expires.
2. **Track per-connection deadlines** in the `Connection` struct and update them whenever quiche reports a new timeout.
3. **Integrate with the event loop** so we fire callbacks only when the next deadline is due (instead of polling continuously).
4. **Exercise the new logic in tests** (unit or integration) to confirm idle connections are closed and that timers are rescheduled when traffic resumes.

## Tasks

1. **Track deadlines and schedule timers**
   - Extend `Connection` with an absolute deadline (`timeout_deadline_ms`) derived from `conn.conn.timeoutAsMillis()` (falling back to `null` when quiche reports no pending timer).
   - Update `QuicServer.updateTimer()` so it writes `connection.timeout_deadline_ms` and registers/updates an event-loop timer handle. We can either:
     - (Option A) Maintain a min-heap of deadlines and run a single timer for the earliest deadline.
     - (Option B) Attach one libev timer per connection.
   - When a connection is closed, cancel its timer handle.

2. **Implement `checkTimeouts()`**
   - Walk all connections whose deadline ≤ now.
   - Call `conn.conn.onTimeout()` (quiche API) and handle the result (drain egress, close connection if `isClosed()` becomes true, etc.).
   - After processing, fetch the new timeout (`timeoutAsMillis()`) and reschedule.

3. **Wire up the global callback**
   - Replace the TODO in `onTimeoutTimer()` with a call to `self.checkTimeouts()`.
   - Make sure the timer is armed whenever the server starts (`init()` / `run()`) and re-armed as deadlines move.

4. **Testing & validation**
   - Add a regression test that opens a connection, stops sending traffic, and asserts that the server closes it after the configured idle timeout.
   - Verify we still drain outstanding packets and do not leak timers across reconnects.
   - Confirm quiche’s retransmit timer fires by simulating packet loss (optional, but at least ensure `onTimeout()` is exercised in logs/qlog).

Once these steps land, the server will cleanly terminate idle peers and honour quiche’s retransmit timers, removing the last known blocker for the client harness described in `docs/client-spec.md`.
