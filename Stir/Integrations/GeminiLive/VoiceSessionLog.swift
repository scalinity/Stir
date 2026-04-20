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
    /// subtracting timestamps by hand.
    nonisolated(unsafe) private static var sessionStartedAt: Date?

    static func sessionStart() {
        sessionStartedAt = Date()
        log("session.start")
    }

    static func sessionEnd() {
        log("session.end")
        sessionStartedAt = nil
    }

    /// Emit one log line.
    /// - Parameters:
    ///   - tag: dot-separated event code (e.g. `mint.fail`,
    ///          `ws.send_failed`, `state.advance`).
    ///   - kv: optional key=value attributes; all values coerced to
    ///         String via `String(describing:)`.
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
            .map { "\($0.key)=\($0.value)" })
        let tail = pairs.isEmpty ? "" : " " + pairs.joined(separator: " ")
        print("[voice] \(ts) \(tag)\(tail)")
    }

    /// Convenience for error paths. Truncates the description to 200
    /// chars so a wall-of-text URLError doesn't bury the transcript.
    static func logError(_ tag: String, error: any Error, _ kv: [String: Any] = [:]) {
        var extended = kv
        let desc = String(describing: error)
        let truncated = desc.count > 200 ? String(desc.prefix(200)) + "…" : desc
        extended["error"] = truncated
        log(tag, extended)
    }
}

#endif
