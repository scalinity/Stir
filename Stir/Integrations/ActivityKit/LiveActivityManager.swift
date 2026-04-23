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

    enum EndReason {
        case completed
        case cancelled
    }
}
