// RecipePlan + remaining-duration math.
//
// Used by Cook Mode's recipe strip to render "~T min left" — the sum
// of `step.timerSeconds` for steps at `currentIndex` and beyond.
// Mockup spec: `stir-app-design/project/DesignMockups/06_cook_mode_tap.html:80-85`.
//
// Timer-less steps contribute zero to the estimate. This is a known
// undercount — recipes whose steps lack `timerSeconds` produce a
// degenerate "0 min left" label rather than a guess. That's the spec
// (`feedback_summary_present` math style) — never lie to the user
// about how much cooking is left.

import CoreData
import Foundation

extension RecipePlan {
    /// Sum of `timerSeconds` across steps at indices `>= fromStepIndex`.
    /// Returns 0 when out of bounds, when every remaining step is
    /// timer-less, or when the plan has no steps. Clamps `fromStepIndex`
    /// to valid range so callers don't have to.
    func remainingDurationSec(fromStepIndex index: Int) -> Int {
        let steps = stepArray
        guard !steps.isEmpty else { return 0 }
        let clamped = max(0, min(index, steps.count))
        return steps[clamped...]
            .map { Int($0.timerSeconds) }
            .reduce(0, +)
    }

    /// Convenience: minutes (rounded up via ceil-division) for the
    /// recipe strip label. Returns 0 when no remaining timer-bearing
    /// steps. Distinct from the wall-clock remaining-time estimate
    /// solve provides — that includes prep / non-timed work that the
    /// per-step `timerSeconds` field doesn't carry.
    func remainingDurationMinutes(fromStepIndex index: Int) -> Int {
        let secs = remainingDurationSec(fromStepIndex: index)
        guard secs > 0 else { return 0 }
        return (secs + 59) / 60
    }
}
