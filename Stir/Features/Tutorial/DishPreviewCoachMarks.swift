// DishPreviewCoachMarks
//
// Coach-mark sequence for the dish preview screen (the gate before
// Cook Mode). Surfaces the time/servings meta, "why this fits"
// reasoning, and the Start Cooking CTA.

import Foundation

enum DishPreviewCoachMarks {
    static let steps: [CoachMarkStep] = [
        CoachMarkStep(
            id: "meta",
            anchor: .dishMeta,
            placement: .below,
            title: "Time and servings up front",
            message: "Quick scan: how long the dish takes, how many it feeds, and how many pans you'll dirty.",
        ),
        CoachMarkStep(
            id: "why_fits",
            anchor: .dishWhyItFits,
            placement: .below,
            title: "Why this dish fits",
            message: "Stir explains in one line why this dinner made sense for tonight's pantry.",
        ),
        CoachMarkStep(
            id: "start_cooking",
            anchor: .dishStartCooking,
            placement: .above,
            title: "Start Cooking",
            message: "Open the step-by-step Cook Mode. You can flip into hands-free Voice Mode from there.",
            requiredAction: .startCookingTap,
        ),
    ]
}
