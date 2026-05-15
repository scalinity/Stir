// NotificationHistoryStore
//
// UserDefaults-backed bookkeeping for the leftovers-followup +
// use-soon schedulers. Tracks fire timestamps + actioned-or-not per
// fire and exposes the two policy primitives both schedulers need:
//
//   1. 2-per-7d rolling cap — refuse to schedule when the last 7d
//      already saw 2 fires. Prevents a chatty user from getting
//      multiple back-to-back nudges.
//   2. 14d unactioned-streak suppression — when the prior 2 fires
//      both went unactioned, suppress further fires for 14 days.
//      An action (deep-link tap, leftovers session start, etc.)
//      clears the suppression immediately.
//
// Generic over storage keys so each scheduler gets its own isolated
// bucket.

import Foundation
import OSLog

@MainActor
final class NotificationHistoryStore {
    private let defaults: UserDefaults
    private let stateKey: String
    private let suppressionKey: String
    private let telemetry: PostHogClient
    private static let maxEntries = 5
    /// CR2-W2 / CA1-02: surface the 2-per-7d cap as a named constant so the
    /// schedulers can read it instead of duplicating `>= 2` literals at
    /// each callsite. Keeps the policy invariant in one place.
    static let weeklyCap = 2
    /// CA1-02: when checking for an unactioned streak, only count fires
    /// from this trailing window. Without this, FIFO-bound `entries`
    /// can carry old (unactioned, multi-week-stale) fires that wrongly
    /// arm the 14-day suppression on a fresh schedule. 30 days is the
    /// "if you went on vacation, we don't punish you" window.
    static let unactionedStreakWindowSec: TimeInterval = 30 * 86_400

    struct Entry: Codable, Equatable {
        let fireAt: Date
        var actioned: Bool
    }

    init(
        defaults: UserDefaults,
        stateKey: String,
        suppressionKey: String,
        telemetry: PostHogClient = .shared,
    ) {
        self.defaults = defaults
        self.stateKey = stateKey
        self.suppressionKey = suppressionKey
        self.telemetry = telemetry
    }

    var suppressedUntil: Date? {
        defaults.object(forKey: suppressionKey) as? Date
    }

    /// Fire timestamps within the trailing 7-day window from `asOf`.
    /// Used for the 2-per-week cap check.
    func firesInLastWeek(asOf: Date) -> [Date] {
        let cutoff = asOf.addingTimeInterval(-7 * 86_400)
        return load()
            .filter { $0.fireAt >= cutoff }
            .map { $0.fireAt }
    }

    /// Append a scheduled-fire entry. Also evaluates the unactioned
    /// streak — if the prior 2 RECENT entries were both unactioned, set
    /// the 14-day suppression starting now. The recency filter (CA1-02)
    /// stops stale entries (e.g., 6-week-old fires retained by the
    /// FIFO bound) from arming suppression on a fresh fire. Bounded at
    /// maxEntries entries so storage stays trivially small.
    func recordScheduled(fireAt: Date) {
        var entries = load()
        let now = Date()
        let recencyCutoff = now.addingTimeInterval(-Self.unactionedStreakWindowSec)
        let recentPrior = entries
            .suffix(Self.weeklyCap)
            .filter { $0.fireAt >= recencyCutoff }
        if recentPrior.count == Self.weeklyCap,
           recentPrior.allSatisfy({ !$0.actioned })
        {
            defaults.set(
                now.addingTimeInterval(14 * 86_400),
                forKey: suppressionKey,
            )
        }
        entries.append(Entry(fireAt: fireAt, actioned: false))
        if entries.count > Self.maxEntries {
            entries = Array(entries.suffix(Self.maxEntries))
        }
        save(entries)
    }

    /// Mark the most recent fire as actioned. Also clears any active
    /// suppression — the user just demonstrated engagement.
    ///
    /// SCA-376: suppression-clear is unconditional. Even when the
    /// history is empty (no prior fires), the user's engagement (e.g.
    /// a use-soon card tap from TonightHomeView routed via
    /// UseSoonScheduler.recordAction) clears any phantom suppression
    /// entry. The pre-fix early-return at `guard let last ...`
    /// skipped the removeObject call, leaving a stale suppression-until
    /// date in place for the entire 14-day window even though the
    /// user engaged.
    func markMostRecentActioned(at _: Date) {
        // SCA-376: clear suppression FIRST (always), then mark fire
        // actioned IFF history exists.
        defaults.removeObject(forKey: suppressionKey)
        var entries = load()
        guard let last = entries.indices.last else { return }
        entries[last].actioned = true
        save(entries)
    }

    /// Test seam — wipe both buckets.
    func reset() {
        defaults.removeObject(forKey: stateKey)
        defaults.removeObject(forKey: suppressionKey)
    }

    private func load() -> [Entry] {
        guard let data = defaults.data(forKey: stateKey) else { return [] }
        do {
            return try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            // CR1-S5: a decode failure means the user's history just got
            // reset (which reopens the door to spam). Surface to OSLog
            // so a future incompatible Entry shape change is observable
            // rather than silently wiping the rolling-cap state.
            Logger.notifications.warning(
                "NotificationHistoryStore decode failed for key=\(self.stateKey, privacy: .public): \(error.localizedDescription, privacy: .private)",
            )
            // SCA-374 + SCA-398: surface to PostHog so an Entry-shape
            // regression (breaking change to `Entry: Codable`) shows up
            // in dashboards across the user base, not just in individual
            // sysdiagnose captures.
            // SCA-398 retired the prior `error_description: error
            // .localizedDescription` raw OS-string property in favor of
            // the closed-vocab `error_reason: HistoryDecodeErrorReason
            // .classify(error).rawValue`. Same SCA-367 pattern that
            // bounded the rollback-failure event surface.
            telemetry.capture(.notificationHistoryDecodeFailed, properties: [
                "state_key": stateKey,
                "error_reason": HistoryDecodeErrorReason.classify(error).rawValue,
            ])
            return []
        }
    }

    private func save(_ entries: [Entry]) {
        do {
            let data = try JSONEncoder().encode(entries)
            defaults.set(data, forKey: stateKey)
        } catch {
            // SCA-319: mirror the load() warning at line 115. A silent
            // encode failure would mean the rolling cap silently stops
            // working — both sides of the persistence path now log on
            // failure so a future Entry-shape regression is observable.
            Logger.notifications.warning(
                "NotificationHistoryStore encode failed for key=\(self.stateKey, privacy: .public): \(error.localizedDescription, privacy: .private)",
            )
        }
    }
}

// MARK: - SCA-398: closed-vocab decode-failure reason

/// Closed-vocabulary error reason for the `notification_history_decode_failed`
/// PostHog event. Bounds the dashboard-property surface so a future
/// Foundation `JSONDecoder.localizedDescription` widening can't leak
/// implementation-defined OS strings into PostHog at indefinite retention.
/// Mirrors the SCA-367 `RollbackErrorReason` pattern for the rollback-
/// failure event.
///
/// Per ADR 0009, the underlying `Entry` blob carries `fireAt: Date +
/// actioned: Bool` only — no user content. The OS-supplied
/// `localizedDescription` was permitted on those grounds, but the
/// review (CR3-W4 / SA3-W3 in the SCA-355 cluster review) flagged the
/// inconsistency with SCA-367; SCA-398 closes the loop.
enum HistoryDecodeErrorReason: String, Sendable, CaseIterable, Equatable {
    /// `DecodingError.dataCorrupted` — the bytes parsed but failed an
    /// invariant the decoder enforced (e.g. invalid date format).
    case dataCorrupted
    /// `DecodingError.keyNotFound` — required `Entry` key missing from
    /// the encoded payload (most common Entry-shape regression).
    case keyNotFound
    /// `DecodingError.typeMismatch` — encoded value's type doesn't
    /// match the `Entry` field (Bool became String, etc.).
    case typeMismatch
    /// `DecodingError.valueNotFound` — the key was present but the
    /// value was null where a non-optional was expected.
    case valueNotFound
    /// Anything else (corrupt bytes pre-parse, future DecodingError
    /// case Apple adds, non-DecodingError throw).
    case unknown

    /// Map an arbitrary `Error` (the JSONDecoder throw) to a closed-
    /// vocab reason. Used at the SCA-374 telemetry capture site so
    /// PostHog never sees raw OS-supplied `localizedDescription`
    /// strings. Same shape as `RollbackErrorReason.classify(_:)`.
    static func classify(_ error: Error) -> HistoryDecodeErrorReason {
        guard let decoding = error as? DecodingError else { return .unknown }
        switch decoding {
        case .dataCorrupted: return .dataCorrupted
        case .keyNotFound: return .keyNotFound
        case .typeMismatch: return .typeMismatch
        case .valueNotFound: return .valueNotFound
        @unknown default: return .unknown
        }
    }
}
