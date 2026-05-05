// OnboardingOptions
//
// The curated lists of allergens / diets / goals / equipment offered during
// setup. Step 2 uses hand-picked coverage of the common cases; the full
// ingredient ontology (for scan + solve hints) ships in step 3.
//
// Display strings are user-facing English per spec §"What NOT to reopen"
// (US-only launch). The raw value written to Core Data is lowercase-kebab,
// stable across UI copy changes.

import Foundation

enum AllergenOption: String, CaseIterable, Sendable, Equatable {
    case peanut
    case treeNut = "tree_nut"
    case nut       // Coarse "nut-free" used by mockup 02 onboarding chips.
    case dairy
    case egg
    case soy
    case gluten
    case shellfish
    case fish
    case sesame

    var displayName: String {
        switch self {
        case .peanut:    return "Peanut"
        case .treeNut:   return "Tree nut"
        case .nut:       return "Nut"
        case .dairy:     return "Dairy"
        case .egg:       return "Egg"
        case .soy:       return "Soy"
        case .gluten:    return "Gluten"
        case .shellfish: return "Shellfish"
        case .fish:      return "Fish"
        case .sesame:    return "Sesame"
        }
    }
}

enum DietOption: String, CaseIterable, Sendable, Equatable {
    case vegetarian
    case vegan
    case pescatarian
    case halal
    case kosher
    case keto
    case paleo
    case mediterranean
    case lowCarb = "low_carb"
    case whole30

    var displayName: String {
        switch self {
        case .vegetarian:    return "Vegetarian"
        case .vegan:         return "Vegan"
        case .pescatarian:   return "Pescatarian"
        case .halal:         return "Halal"
        case .kosher:        return "Kosher"
        case .keto:          return "Keto"
        case .paleo:         return "Paleo"
        case .mediterranean: return "Mediterranean"
        case .lowCarb:       return "Low carb"
        case .whole30:       return "Whole30"
        }
    }
}

enum DislikeOption: String, CaseIterable, Sendable, Equatable {
    case cilantro
    case mushrooms
    case olives
    case blueCheese       = "blue_cheese"
    case anchovies
    case liver
    case bellPepper       = "bell_pepper"
    case beets
    case tofu
    case eggplant
    case seafood
    case brusselsSprouts  = "brussels_sprouts"

    var displayName: String {
        switch self {
        case .cilantro:          return "Cilantro"
        case .mushrooms:         return "Mushrooms"
        case .olives:            return "Olives"
        case .blueCheese:        return "Blue cheese"
        case .anchovies:         return "Anchovies"
        case .liver:             return "Liver"
        case .bellPepper:        return "Bell pepper"
        case .beets:             return "Beets"
        case .tofu:              return "Tofu"
        case .eggplant:          return "Eggplant"
        case .seafood:           return "Seafood"
        case .brusselsSprouts:   return "Brussels sprouts"
        }
    }
}

enum GoalOption: String, CaseIterable, Sendable, Equatable {
    case quickWeeknights = "quick_weeknights"
    case lessFoodWaste = "less_food_waste"
    case moreVegetables = "more_vegetables"
    case newCuisines = "new_cuisines"
    case highProtein = "high_protein"
    case lowSugar = "low_sugar"
    case useLeftovers = "use_leftovers"
    case budget
    case familyFriendly = "family_friendly"
    case mealPrep = "meal_prep"

    /// User-facing display name for Settings + `personalizedBody` clauses.
    /// Kept as noun phrases so the body sentence "your <name> goals" reads
    /// naturally; mockup-faithful verb-phrase labels for onboarding chips
    /// (e.g. "eat more vegetables") live in `SetupPreferencesView`'s
    /// `goalsForOnboarding` table.
    var displayName: String {
        switch self {
        case .quickWeeknights: return "Quicker weeknights"
        case .lessFoodWaste:   return "Less food waste"
        case .moreVegetables:  return "More vegetables"
        case .newCuisines:     return "New cuisines"
        case .highProtein:     return "High protein"
        case .lowSugar:        return "Low sugar"
        case .useLeftovers:    return "Use leftovers"
        case .budget:          return "Budget"
        case .familyFriendly:  return "Family friendly"
        case .mealPrep:        return "Meal prep"
        }
    }
}
