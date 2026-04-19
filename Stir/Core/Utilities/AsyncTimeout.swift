// AsyncTimeout
//
// Generic async timeout wrapper. URLSession's default resource timeout is
// effectively infinite (7 days on iOS), so a partial-response hang at the
// TCP level — server accepts the connection and never replies — leaves
// awaited calls pending for hours. Wrapping the call in `withTimeout`
// throws `StirError.timeout(operation:seconds:)` after a deterministic
// wall-clock budget.
//
// Use it for any network call where a hung connection would block the UI
// or other calls behind a deduplication lock (e.g. `configBootstrap`
// refresh inside `runRefresh` — the `refreshTask` de-dup would park all
// subsequent foreground transitions behind the hung one until the
// URLSession resource timeout eventually fires).
//
// Pattern:
//
//     let response = try await withTimeout(seconds: 15, operation: "configBootstrap") {
//         try await sessionClient.configBootstrap()
//     }
//
// Implementation uses `withThrowingTaskGroup` — spawns the real operation
// and a racing sleep-then-throw task. Whichever finishes first wins; the
// loser is cancelled. Cancellation propagates into the inner operation's
// `try await` points via Swift's cooperative cancellation, so a timed-out
// URLSession request is also cancelled at the transport layer (not just
// abandoned in the caller).

import Foundation

/// Race an async operation against a wall-clock timeout.
/// Throws `StirError.timeout(operation:seconds:)` if the operation doesn't
/// complete within `seconds`. Re-throws the operation's own error on normal
/// failure.
///
/// - Parameters:
///   - seconds: deadline in seconds (must be > 0).
///   - operation: a short label used in the timeout error message and
///     telemetry. Not user-visible.
///   - work: the async closure to race. Must be `@Sendable` to allow the
///     task group to execute it on any executor.
func withTimeout<T: Sendable>(
    seconds: Double,
    operation: String,
    _ work: @escaping @Sendable () async throws -> T,
) async throws -> T {
    precondition(seconds > 0, "withTimeout: seconds must be positive")
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw StirError.timeout(operation: operation, seconds: seconds)
        }
        // `next()` returns whichever child task finishes first. Force-unwrap
        // is safe: we just added two tasks, one must produce a result (even
        // if it's a thrown error, `next()` re-throws and we exit the group).
        let result = try await group.next()!
        // Cancel the sibling task — either the timer (if work won) or the
        // work (if timeout won and bubbled here via throw, which we won't
        // reach). Redundant but belt-and-suspenders.
        group.cancelAll()
        return result
    }
}
