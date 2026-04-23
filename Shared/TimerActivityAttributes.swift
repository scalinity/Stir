// TimerActivityAttributes
//
// ActivityKit contract for the Cook Mode timer Live Activity.
// Compiled into BOTH Stir (which starts/updates/ends activities via
// LiveActivityManager) and StirWidgets (which renders Lock Screen +
// Dynamic Island via TimerLiveActivity). Types MUST match exactly
// across targets — that's why this file lives in `Shared/`.
//
// Invariants:
//   - `ContentState` carries only fields that change mid-timer:
//     fire date, paused-remaining seconds, isComplete. Static fields
//     (recipe title, step number at activity start) live on the
//     attributes type itself and cannot change during the activity's
//     lifetime.
//   - `fireDate` is authoritative: the widget uses Text(timerInterval:)
//     for auto-ticking countdowns so the main app doesn't need to
//     update the activity every second.
//   - `pausedRemainingSec` is non-nil only when the CookTimer state is
//     `.paused`; setting it flips the widget to a static display.
//   - `isComplete` is set once and never flipped back (matches the
//     CookTimer's terminal `.completed` / `.cancelled` states).

import ActivityKit
import Foundation

public struct TimerActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Authoritative fire date. Text(timerInterval: ...) in the
        /// widget views ticks down automatically without per-second
        /// updates.
        public let fireDate: Date
        /// Non-nil ⇒ timer is paused; value = remaining seconds at
        /// pause. The widget renders this statically (no auto-tick).
        public let pausedRemainingSec: Int?
        /// Terminal flag — set on natural fire, user-marked-complete,
        /// or cancel. Once true, the activity lingers briefly before
        /// being ended via `activity.end(...)`.
        public let isComplete: Bool

        public init(
            fireDate: Date,
            pausedRemainingSec: Int? = nil,
            isComplete: Bool = false,
        ) {
            self.fireDate = fireDate
            self.pausedRemainingSec = pausedRemainingSec
            self.isComplete = isComplete
        }
    }

    public let timerId: UUID
    public let recipeTitle: String
    public let stepDescription: String
    public let stepNumber: Int
    public let totalSteps: Int
    /// Total seconds the timer was initially configured for. Static
    /// for the activity's lifetime — pause/resume updates fireDate on
    /// ContentState, but the denominator for the progress bar stays
    /// pinned here. Previously the widget derived a coarse 60-min
    /// upper bound from current-remaining, making 2-min timers start
    /// at 100% full and 60-min timers barely move (W19).
    public let initialDurationSec: Int

    public init(
        timerId: UUID,
        recipeTitle: String,
        stepDescription: String,
        stepNumber: Int,
        totalSteps: Int,
        initialDurationSec: Int,
    ) {
        self.timerId = timerId
        self.recipeTitle = recipeTitle
        self.stepDescription = stepDescription
        self.stepNumber = stepNumber
        self.totalSteps = totalSteps
        self.initialDurationSec = initialDurationSec
    }
}
