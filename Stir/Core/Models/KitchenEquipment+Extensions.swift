// KitchenEquipment type-safety extensions.
//
// Per spec §4.3, `code` is an opaque string that matches the bundled ingredient
// ontology. Step 2 keeps this loose — the full KitchenEquipment catalog lands
// in step 3 (scan + solve) when we have the JSON asset bundled.

import CoreData
import Foundation

extension KitchenEquipment {
    /// Well-known equipment codes that step-2 onboarding offers as toggles.
    /// Extended significantly in step 3 alongside the full ingredient ontology.
    enum CommonCode: String, CaseIterable, Sendable {
        case oven
        case stovetop
        case microwave
        case airFryer = "air_fryer"
        case instantPot = "instant_pot"
        case slowCooker = "slow_cooker"
        case blender
        case foodProcessor = "food_processor"
        case standMixer = "stand_mixer"
        case rice_cooker
        case grill
        case griddle
        case cast_iron
        case nonstickPan = "nonstick_pan"
        case sheetPan = "sheet_pan"
        case dutchOven = "dutch_oven"
        case skillet

        var displayName: String {
            switch self {
            case .oven:           return "Oven"
            case .stovetop:       return "Stovetop"
            case .microwave:      return "Microwave"
            case .airFryer:       return "Air fryer"
            case .instantPot:     return "Instant Pot"
            case .slowCooker:     return "Slow cooker"
            case .blender:        return "Blender"
            case .foodProcessor:  return "Food processor"
            case .standMixer:     return "Stand mixer"
            case .rice_cooker:    return "Rice cooker"
            case .grill:          return "Grill"
            case .griddle:        return "Griddle"
            case .cast_iron:      return "Cast iron pan"
            case .nonstickPan:    return "Nonstick pan"
            case .sheetPan:       return "Sheet pan"
            case .dutchOven:      return "Dutch oven"
            case .skillet:        return "Skillet"
            }
        }
    }

    var typedCode: CommonCode? {
        get { code.flatMap(CommonCode.init(rawValue:)) }
        set { code = newValue?.rawValue }
    }
}
