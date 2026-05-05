// TutorialManager
//
// Tracks completion state for in-app tutorials. State is mirrored from
// UserDefaults into an in-memory `Set<TutorialKey>` that is the
// `@Observable` source of truth for SwiftUI; `UserDefaults` provides
// durability across launches. Both are kept in lock-step on
// `markCompleted` / `reset`.
//
// Why both: the original implementation read `UserDefaults` directly on
// every `isCompleted(_:)` call. `@Observable` cannot track that — the
// property `isCompleted` is a method, not a stored property — so view
// invalidation never fired when the flag flipped. Settings → "Show
// tutorial again" was therefore a dead button (review C1). Storing the
// set in a tracked stored property fixes the gating.
//
// UserDefaults writes are verified via readback. A no-op (sandbox
// restrictions, low-disk + sync-pending) logs to Sentry rather than
// silently disagreeing with PostHog (review DB2 W2).

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class TutorialManager {
    static let shared = TutorialManager()

    /// In-memory mirror of the per-key completion flags. Tracked by
    /// `@Observable`, so reads from views participate in invalidation.
    private(set) var completedKeys: Set<TutorialKey>

    private let defaults: UserDefaults
    private let sentry: any SentryReporting

    init(
        defaults: UserDefaults = .standard,
        sentry: any SentryReporting = SentryReporter.shared,
    ) {
        self.defaults = defaults
        self.sentry = sentry
        // Hydrate from UserDefaults at construction so the in-memory
        // mirror is correct on first use without a separate warmup
        // step.
        self.completedKeys = Set(
            TutorialKey.allCases.filter { defaults.bool(forKey: $0.defaultsKey) },
        )
    }

    func isCompleted(_ key: TutorialKey) -> Bool {
        completedKeys.contains(key)
    }

    /// Mark a tutorial resolved (Done or Skip — both terminal). Writes
    /// to UserDefaults, mutates the in-memory set, and verifies the
    /// write landed.
    func markCompleted(_ key: TutorialKey) {
        completedKeys.insert(key)
        defaults.set(true, forKey: key.defaultsKey)
        verifyWrite(key: key, expected: true)
    }

    /// Clear a tutorial — used by the Settings replay affordance. The
    /// `@Observable` invalidation here is what makes the modifier
    /// re-evaluate and re-present.
    func reset(_ key: TutorialKey) {
        completedKeys.remove(key)
        defaults.removeObject(forKey: key.defaultsKey)
        verifyWrite(key: key, expected: false)
    }

    /// Reset every known tutorial. Used by Settings → "Replay
    /// tutorials" (`RootCoordinator.replayAllTutorials`). Atomic at
    /// the in-memory level (single `removeAll` on the observable
    /// set); UserDefaults writes are best-effort but flushed via a
    /// trailing `synchronize()` so a force-quit mid-loop either
    /// leaves every key cleared or none.
    func resetAll() {
        completedKeys.removeAll()
        for key in TutorialKey.allCases {
            defaults.removeObject(forKey: key.defaultsKey)
        }
        // Best-effort durable flush. UserDefaults will sync on the
        // next backgrounding regardless; this just narrows the
        // crash window.
        defaults.synchronize()
    }

    /// Read back the UserDefaults state and breadcrumb a mismatch.
    /// `defaults.set` cannot throw but can no-op (corrupt plist, low
    /// disk, sandbox restriction) — without this verification a
    /// `tutorial_completed` event would fire while the device still
    /// re-presents the tour on next launch.
    private func verifyWrite(key: TutorialKey, expected: Bool) {
        let actual = defaults.bool(forKey: key.defaultsKey)
        guard actual != expected else { return }
        Logger.ui.error(
            "tutorial_userdefaults_write_failed key=\(key.rawValue, privacy: .public) expected=\(expected, privacy: .public) actual=\(actual, privacy: .public)",
        )
        sentry.breadcrumb(
            category: "tutorial",
            message: "userdefaults_write_failed",
            data: [
                "tutorial_id": key.telemetryID,
                "expected": String(expected),
                "actual": String(actual),
            ],
        )
    }
}
