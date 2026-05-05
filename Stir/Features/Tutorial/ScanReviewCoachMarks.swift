// ScanReviewCoachMarks
//
// Coach-mark sequence for the parsed-ingredients review screen. Walks
// the Confirmed bucket, Needs Review bucket, manual Add chip, and the
// Solve button. Solve is action-gated on the real CTA tap.

import Foundation

enum ScanReviewCoachMarks {
    static let steps: [CoachMarkStep] = [
        CoachMarkStep(
            id: "confirmed",
            anchor: .scanConfirmedSection,
            placement: .below,
            title: "Confirmed picks",
            message: "Stir parsed these with high confidence. Skim them — anything obviously wrong?",
        ),
        CoachMarkStep(
            id: "needs_review",
            anchor: .scanNeedsReviewSection,
            placement: .below,
            title: "Needs a glance",
            message: "These are best guesses. Tap a chip to edit the name; long-press for remove.",
        ),
        CoachMarkStep(
            id: "add",
            anchor: .scanAddChip,
            placement: .above,
            title: "Add what's missing",
            message: "Stir didn't see something? Use Add to type it in.",
        ),
        CoachMarkStep(
            id: "solve",
            anchor: .scanSolveButton,
            placement: .above,
            title: "Hit Solve dinner",
            message: "Once your ingredients look right, Solve dinner gives you three ranked dinners.",
            requiredAction: .solveTap,
        ),
    ]
}
