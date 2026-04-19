// SuggestedDish type-safety extensions.

import CoreData
import Foundation

extension SuggestedDish {
    enum FitLabel: String, CaseIterable, Sendable {
        case fastest
        case leastWaste = "least_waste"
        case bestFit = "best_fit"
        case usesWhatYouHave = "uses_what_you_have"
        case newToYou = "new_to_you"
    }

    var typedFitLabelPrimary: FitLabel {
        get { fitLabelPrimary.flatMap(FitLabel.init(rawValue:)) ?? .bestFit }
        set { fitLabelPrimary = newValue.rawValue }
    }

    var typedFitLabelSecondary: FitLabel? {
        get { fitLabelSecondary.flatMap(FitLabel.init(rawValue:)) }
        set { fitLabelSecondary = newValue?.rawValue }
    }
}
