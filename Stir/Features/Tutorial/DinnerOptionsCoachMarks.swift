// DinnerOptionsCoachMarks
//
// Coach-mark sequence for the three-up ranked dinners screen. All
// three steps anchor on the rank-1 card (`.dinnerCardRank1`). The
// FitLabel renders inside the card; a separate FitLabel anchor would
// not change what the spotlight covers.

import Foundation

enum DinnerOptionsCoachMarks {
    static let steps: [CoachMarkStep] = [
        CoachMarkStep(
            id: "card",
            anchor: .dinnerCardRank1,
            placement: .below,
            title: "Three dinners, ranked",
            message: "Stir picks dinners that fit what's in your kitchen, ranked by least friction.",
        ),
        CoachMarkStep(
            id: "fit",
            anchor: .dinnerCardRank1,
            placement: .below,
            title: "Read the fit label",
            message: "HIGH MATCH means you have everything. EASY SWAP means one substitution. MISSING ITEMS means a quick grocery run.",
        ),
        CoachMarkStep(
            id: "tap_card",
            anchor: .dinnerCardRank1,
            placement: .below,
            title: "Tap a card",
            message: "Open any dinner to see the recipe before you commit to cooking.",
            requiredAction: .cardTap,
        ),
    ]
}
