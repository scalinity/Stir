// LiveActivityManager
//
// Thin wrapper over ActivityKit's Activity<TimerActivityAttributes>
// that TimerService calls when a CookTimer transitions through its
// lifecycle. Kept separate from TimerService so the ActivityKit
// availability gate (iOS 16.1+) is isolated and the rest of the timer
// logic stays testable without ActivityKit mocks.
//
// Lifecycle mapping:
//   timer.start()         → Activity.request(...)
//   timer.pause()         → activity.update(pausedRemainingSec: N)
//   timer.resume()        → activity.update(pausedRemainingSec: nil, fireDate: new)
//   timer.markCompleted() → activity.end(...)
//   timer.cancel()        → activity.end(..., dismissalPolicy: .immediate)
//
// The manager is idempotent: re-requesting an activity for a timerId
// that's already active is a no-op; end() on an unknown id is a no-op.
// This matches TimerService's "foreground reconciliation" path where
// we may call markCompleted on a timer whose activity already ended
// naturally via the ActivityKit system.

import ActivityKit
import Foundation
import OSLog

@MainActor
final class LiveActivityManager {
    /// Process-once gate for `reconcileOnLaunch`. RootCoordinator's
    /// `bootstrap()` runs on cold launch BUT ALSO on `retry()` and on
    /// CloudKit-account-change — without this flag, my reconcile would
    /// end every persisted activity on every re-bootstrap, killing the
    /// in-progress Lock Screen surface mid-cook for any user who hits
    /// Retry on the offline banner or signs into a different iCloud
    /// account. Set the first time `reconcileOnLaunch` runs; subsequent
    /// calls are no-ops.
    private static var didReconcileOnLaunch = false

    /// Registry of live activities keyed by CookTimer.id. Values are
    /// typed Activity handles so update/end calls don't need string
    /// lookups. Cleared on end() or cold-launch.
    private var activities: [UUID: Activity<TimerActivityAttributes>] = [:]

    /// Whether the system currently allows new Live Activities. iOS
    /// gates this via ActivityAuthorizationInfo — user may have
    /// disabled Live Activities in Settings. Check before requesting.
    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Whether an activity is already tracked for this timerId. Lets
    /// callers (CookModeViewModel.reconcileTimersOnForeground) decide
    /// whether a resumed running timer needs a fresh `start(...)` after
    /// cold-launch reconciliation cleared every persisted activity.
    func hasActivity(for timerId: UUID) -> Bool {
        activities[timerId] != nil
    }

    /// Cold-launch reconciliation. ActivityKit persists Live Activities
    /// across app force-quit, but our in-memory `activities` dict is
    /// per-process — it's empty on every cold launch. Without this
    /// reconciliation, the app's subsequent end() / update() calls all
    /// hit the empty dict and silently no-op, leaving the stale Lock
    /// Screen activity ticking until the system's ~8h cap removes it.
    /// Observed device-side 2026-05-03: a force-killed mid-cook session
    /// left the activity counting up positive elapsed-since-fire for
    /// hours.
    ///
    /// Strategy: end every persisted activity unconditionally. The
    /// current Cook Mode session (if resumable) will recreate
    /// activities for not-yet-expired running timers via
    /// `CookModeViewModel.reconcileTimersOnForeground`. Edge case: a
    /// brief gap between end and re-create where a backgrounded user
    /// would see the Lock Screen empty — accepted trade-off vs the
    /// counts-up persistence bug.
    ///
    /// **Process-once.** RootCoordinator's `bootstrap()` re-runs on
    /// `retry()` (offline banner) and on CK-account-change; without a
    /// gate, every re-bootstrap would end the user's in-progress
    /// Live Activity. The static `didReconcileOnLaunch` flag closes
    /// that hole.
    ///
    /// Static so RootCoordinator can call it before any
    /// LiveActivityManager instance exists; iterates ActivityKit's
    /// process-global activity list directly.
    static func reconcileOnLaunch() async {
        guard !didReconcileOnLaunch else { return }
        didReconcileOnLaunch = true
        // CA2-10 fix: parallelize end() calls + 2s outer timeout so a
        // pathologically large persisted set or a slow ActivityKit
        // RPC can't stall RootCoordinator's bootstrap step 0 — cold
        // launch latency is brand-critical.
        let activities = Activity<TimerActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        let work = Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for activity in activities {
                    group.addTask { await activity.end(nil, dismissalPolicy: .immediate) }
                }
            }
        }
        let timeout = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            work.cancel()
        }
        await work.value
        timeout.cancel()
    }

    #if DEBUG
    /// Test seam — reset the process-once gate between test cases that
    /// exercise reconcileOnLaunch. Without this, the static flag remains
    /// set after the first call and every subsequent test in the suite
    /// silently no-ops. Production callers must NOT use this.
    static func _testResetReconcileGate() {
        didReconcileOnLaunch = false
    }
    #endif

    /// Start a Live Activity for a timer. No-op if one already exists
    /// for this timerId or if the system has disabled activities.
    @discardableResult
    func start(
        timerId: UUID,
        recipeTitle: String,
        stepDescription: String,
        stepNumber: Int,
        totalSteps: Int,
        fireDate: Date,
    ) -> Activity<TimerActivityAttributes>? {
        guard areActivitiesEnabled else {
            Logger.ui.info("LiveActivity start skipped: activities disabled")
            return nil
        }
        if let existing = activities[timerId] {
            return existing
        }
        // Derive initial duration from fireDate at start time. Pinning
        // here (rather than re-deriving from ContentState per view) so
        // the progress bar's denominator doesn't shift on pause/resume.
        let initialDurationSec = max(1, Int(fireDate.timeIntervalSinceNow.rounded()))
        let attributes = TimerActivityAttributes(
            timerId: timerId,
            recipeTitle: recipeTitle,
            stepDescription: stepDescription,
            stepNumber: stepNumber,
            totalSteps: totalSteps,
            initialDurationSec: initialDurationSec,
        )
        let state = TimerActivityAttributes.ContentState(fireDate: fireDate)
        let content = ActivityContent(state: state, staleDate: fireDate.addingTimeInterval(300))
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil,
            )
            activities[timerId] = activity
            return activity
        } catch {
            Logger.ui.warning("LiveActivity request failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Update a running activity's state. No-op if no activity exists
    /// for this timerId. Callers pass only the fields that change.
    func update(
        timerId: UUID,
        fireDate: Date,
        pausedRemainingSec: Int? = nil,
        isComplete: Bool = false,
    ) async {
        guard let activity = activities[timerId] else { return }
        let state = TimerActivityAttributes.ContentState(
            fireDate: fireDate,
            pausedRemainingSec: pausedRemainingSec,
            isComplete: isComplete,
        )
        let content = ActivityContent(state: state, staleDate: fireDate.addingTimeInterval(300))
        await activity.update(content)
    }

    /// End an activity. Dismissal is immediate on cancel (user
    /// explicitly stopped the timer) and a short delay on natural
    /// completion (so the "Done" affordance lingers briefly).
    func end(timerId: UUID, reason: EndReason) async {
        guard let activity = activities[timerId] else { return }
        activities.removeValue(forKey: timerId)
        let terminal = TimerActivityAttributes.ContentState(
            fireDate: .now,
            pausedRemainingSec: nil,
            isComplete: reason == .completed,
        )
        let content = ActivityContent(state: terminal, staleDate: nil)
        switch reason {
        case .completed:
            await activity.end(content, dismissalPolicy: .after(.now + 4))
        case .cancelled:
            await activity.end(content, dismissalPolicy: .immediate)
        }
    }

    /// Defensive sweep — end every tracked activity with the given
    /// reason. Used by Cook Mode teardown paths (exit/finish/onDisappear)
    /// to guarantee no Live Activity outlives the meal it belongs to,
    /// even if the targeted per-timer cancel loop missed an entry
    /// (e.g., paused timer intentionally skipped by a `where state ==
    /// .running` filter, or an orphan registered before the matching
    /// CookTimer row was lost). Idempotent: each `end(timerId:reason:)`
    /// removes the entry from `activities`, so a follow-up call is a
    /// no-op.
    ///
    /// `Array(activities.keys)` snapshots the key set before iterating
    /// because `end(timerId:reason:)` mutates `activities` via
    /// `removeValue(forKey:)` — iterating the live dict directly would
    /// invalidate the iterator mid-loop.
    func endAll(reason: EndReason) async {
        for id in Array(activities.keys) {
            await end(timerId: id, reason: reason)
        }
    }

    enum EndReason {
        case completed
        case cancelled
    }
}
