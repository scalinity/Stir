// CookModeTapCoachMarks
//
// Coach-mark sequence for the first tap-mode Cook session. Walks the
// step card, timer pill, substitution affordance, and the Next-step
// gesture. Next is action-gated on the real Next tap.
//
// Voice-mode is a separate sequence (`voiceMode` key) — first voice
// session, regardless of when, gets its own walkthrough.

import Foundation

enum CookModeTapCoachMarks {
    static let steps: [CoachMarkStep] = [
        CoachMarkStep(
            id: "step_card",
            anchor: .cookStepCard,
            placement: .below,
            title: "One step at a time",
            message: "Read the current step, do the task, then advance. Stir keeps your place even if the screen sleeps.",
        ),
        CoachMarkStep(
            id: "timer",
            anchor: .cookTimerPill,
            placement: .below,
            title: "Tap timers to start",
            message: "When a step has a duration, the timer pill appears. Tap it to count down — it keeps running on the lock screen.",
        ),
        CoachMarkStep(
            id: "substitute",
            anchor: .cookSubstituteButton,
            placement: .above,
            title: "Out of something?",
            message: "Tap Substitute and Stir checks the rest of the recipe for safety before suggesting a swap.",
        ),
        CoachMarkStep(
            id: "next",
            anchor: .cookNextButton,
            placement: .above,
            title: "Advance when you're ready",
            message: "Tap Next to move to the following step. Try it now to keep going.",
            requiredAction: .nextStepTap,
        ),
    ]
}
