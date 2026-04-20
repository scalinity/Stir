// VoiceSessionLog
//
// DEBUG-only structured print() helper for live-session instrumentation.
// Deliberately NOT routed through `Logger.voice` because:
//   - OSLog `.private` fields are redacted in Xcode's console (shown
//     as `<private>`), which defeats copy-paste triage during D.1
//     validation runs.
//   - OSLog `.public` is a retention problem for anything that might
//     contain user-spoken text, a URL fragment, or an error string
//     that could embed either.
//   - `print()` is DEBUG-only (file wrapped in #if DEBUG) so release
//     builds can't accidentally emit it.
//
// Output shape (one line per event, tab-separated k=v pairs):
//   [voice] 2026-04-20T06:51:12.345Z mint.start tier=premium
//   [voice] 2026-04-20T06:51:12.912Z ws.setup_complete dt_ms=567
//   [voice] 2026-04-20T06:51:15.001Z state.advance from=ready to=userSpeaking
//
// Grep-friendly prefix so you can filter Xcode's console by `[voice]`
// and paste a session transcript directly into a spike doc.

#if DEBUG

import Foundation

@MainActor
enum VoiceSessionLog {
    /// ISO-8601 with ms — wall clock, not uptime. Makes inter-event
    /// delta computation trivial with a spreadsheet.
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Reference start-of-session timestamp. Set at `sessionStart()`;
    /// nil otherwise. Used to emit a `dt_ms=<elapsed>` on every log
    /// line so rapid inspection of the transcript doesn't require
    /// subtracting timestamps by hand. MainActor-isolated via the
    /// enclosing enum's `@MainActor` attribute — deliberately NOT
    /// `nonisolated(unsafe)`. Every call site is already on the main
    /// actor; keeping the isolation compiler-enforced means a future
    /// misuse from a non-MainActor task becomes a build error rather
    /// than a data race.
    private static var sessionStartedAt: Date?

    static func sessionStart() {
        sessionStartedAt = Date()
        log("session.start")
    }

    static func sessionEnd() {
        if let start = sessionStartedAt {
            let duration = Int(Date().timeIntervalSince(start) * 1000)
            log("session.end", ["duration_ms": duration])
        } else {
            log("session.end")
        }
        sessionStartedAt = nil
    }

    /// Emit one log line.
    /// - Parameters:
    ///   - tag: dot-separated event code (e.g. `mint.fail`,
    ///          `ws.send_failed`, `state.advance`).
    ///   - kv: optional key=value attributes; all values coerced to
    ///         String via `String(describing:)`. Values containing
    ///         spaces are double-quoted so the line stays scannable
    ///         (a bare `error=Error Domain=NSURLErrorDomain` would
    ///         otherwise look like two attributes).
    static func log(_ tag: String, _ kv: [String: Any] = [:]) {
        let now = Date()
        let ts = formatter.string(from: now)
        var pairs: [String] = []
        if let start = sessionStartedAt {
            let dt = Int(now.timeIntervalSince(start) * 1000)
            pairs.append("dt_ms=\(dt)")
        }
        pairs.append(contentsOf: kv
            .sorted { $0.key < $1.key }
            .map { key, value in
                let s = String(describing: value)
                let escaped = s.contains(" ") ? "\"\(s)\"" : s
                return "\(key)=\(escaped)"
            })
        let tail = pairs.isEmpty ? "" : " " + pairs.joined(separator: " ")
        print("[voice] \(ts) \(tag)\(tail)")
    }

    /// Convenience for error paths. Truncates the description to 200
    /// chars so a wall-of-text URLError doesn't bury the transcript,
    /// AND runs through the shared `access_token=...` scrubber so a
    /// token-bearing WebSocket URL embedded in `URLError.userInfo`
    /// doesn't end up in a D.1 transcript pasted back for review.
    /// The token is ephemeral (35 min, single-use) but still live.
    static func logError(_ tag: String, error: any Error, _ kv: [String: Any] = [:]) {
        var extended = kv
        let raw = String(describing: error)
        let scrubbed = LiveWebSocketTransport.scrubAccessToken(raw)
        let truncated = scrubbed.count > 200 ? String(scrubbed.prefix(200)) + "…" : scrubbed
        extended["error"] = truncated
        log(tag, extended)
    }
}

#endif
