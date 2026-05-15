// RecipePlan + remaining-duration math.
//
// Used by Cook Mode's recipe strip to render "~T min left".
// Mockup spec: `stir-app-design/project/DesignMockups/06_cook_mode_tap.html:80-85`.
//
// SCA-422: pre-fix this only summed `step.timerSeconds`, which meant
// a recipe with a single timer-bearing step (e.g. "Grill 3 min") read
// "~3 min left" on every prep / intuitive step before it and the
// label never decreased as the user advanced. The estimate is now a
// blend: per-step `timerSeconds` PLUS an evenly-distributed share of
// the recipe's non-timer overhead (`plan.estimatedMinutes` minus the
// timer sum). Falls back to timer-only math when the plan has no
// `estimatedMinutes` so legacy recipes still render rather than
// going to "0 min left".

import CoreData
import Foundation

extension RecipePlan {
    /// Convenience: minutes (rounded up via ceil-division) for the
    /// recipe strip label. Returns 0 only when the plan has no
    /// duration data at all. When `estimatedMinutes` exceeds the sum
    /// of per-step `timerSeconds`, the overhead is distributed evenly
    /// across every step so prep / intuitive work counts down too —
    /// the label decreases monotonically as the user advances instead
    /// of pinning to the first timer step's value.
    func remainingDurationMinutes(fromStepIndex index: Int) -> Int {
        let steps = stepArray
        guard !steps.isEmpty else { return 0 }
        let clamped = max(0, min(index, steps.count))
        let stepsRemaining = steps.count - clamped
        guard stepsRemaining > 0 else { return 0 }

        let remainingTimerSec = steps[clamped...]
            .map { Int($0.timerSeconds) }
            .reduce(0, +)

        let totalEstimatedSec = Int(estimatedMinutes) * 60
        let totalTimerSec = steps
            .map { Int($0.timerSeconds) }
            .reduce(0, +)
        let overheadSec = max(0, totalEstimatedSec - totalTimerSec)

        // Per-step share of the non-timer overhead. Integer division
        // is fine — the strip rounds up to the next minute, so
        // sub-minute drift between rounding modes is invisible.
        let perStepOverheadSec = overheadSec / steps.count
        let remainingOverheadSec = perStepOverheadSec * stepsRemaining

        let totalRemainingSec = remainingTimerSec + remainingOverheadSec
        guard totalRemainingSec > 0 else { return 0 }
        return (totalRemainingSec + 59) / 60
    }
}
