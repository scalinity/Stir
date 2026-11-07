// Local import review checks the actionable text against current household
// rules. Vocabulary mirrors _shared/hard_rules.ts; parse confidence is unrelated
// to dietary safety. Conservative matches also flag "peanut-free" for review.
import Foundation

enum ImportDietaryConflicts {
    private static let meat = ["beef", "steak", "chicken", "pork", "bacon", "sausage", "ham", "lamb", "turkey", "duck", "veal", "goat", "rabbit", "pepperoni", "salami", "prosciutto", "chorizo", "bratwurst", "venison", "bison"]
    private static let fish = ["fish", "salmon", "tuna", "cod", "halibut", "trout", "mackerel", "sardine", "anchovy", "shrimp", "prawn", "lobster", "crab", "clam", "mussel", "oyster", "scallop", "squid", "octopus", "calamari"]
    private static let dairy = ["milk", "cream", "butter", "cheese", "yogurt", "yoghurt", "ghee", "whey", "casein", "parmesan", "mozzarella", "cheddar", "feta", "ricotta", "kefir", "buttermilk"]
    private static let allergens: [String: [String]] = [
        "nut": ["nut", "nuts", "almond", "cashew", "pistachio", "pecan", "macadamia", "walnut", "hazelnut", "chestnut", "peanut", "groundnut", "brazil nut", "pine nut", "pignoli", "marzipan", "praline", "nougat", "gianduja"],
        "tree_nut": ["almond", "cashew", "pistachio", "pecan", "macadamia", "walnut", "hazelnut", "chestnut", "brazil nut", "pine nut", "pignoli", "tree nut", "marzipan", "praline", "nougat", "gianduja"],
        "peanut": ["peanut", "groundnut"],
        "dairy": ["dairy", "milk", "cream", "butter", "cheese", "yogurt", "yoghurt", "ghee", "whey", "casein", "parmesan", "mozzarella", "cheddar", "feta", "ricotta", "kefir", "buttermilk"],
        "egg": ["egg", "eggs", "albumen", "ovalbumin", "mayonnaise", "meringue"],
        "gluten": ["gluten", "wheat", "barley", "rye", "malt", "spelt", "semolina", "farro", "bulgur", "couscous", "seitan"],
        "fish": ["fish", "salmon", "tuna", "cod", "halibut", "trout", "mackerel", "sardine", "anchovy", "anchovies", "haddock", "tilapia", "pollock", "bonito"],
        "sesame": ["sesame", "tahini", "benne", "gingelly"],
        "soy": ["soy", "soya", "tofu", "tempeh", "edamame", "miso"],
        "shellfish": ["shellfish", "shrimp", "prawn", "lobster", "crab", "clam", "mussel", "oyster", "scallop", "squid", "octopus", "calamari", "crawfish", "crayfish"],
    ]

    static func check(_ recipe: RecipeImportResponse.ImportedRecipe, household: HouseholdProfile) -> [String] {
        let texts = recipe.ingredients.flatMap { [$0.displayName, $0.canonicalSlug ?? "", $0.amountText ?? ""] }
            + recipe.steps.map(\.instructionText)
        return household.dietaryRuleArray.filter { $0.isActive && $0.typedSeverity == .hard }
            .compactMap { rule in
                guard rule.typedKind == .allergy || rule.typedKind == .diet else { return nil }
                let value = (rule.value ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return "A hard dietary rule is missing its value. Check household preferences before saving." }
                let key = value.replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
                let allergy = rule.typedKind == .allergy
                let needles = allergy ? (allergens[key] ?? [value]) : dietKeywords(key)
                let boundary = allergy ? Set(["nut"]) : Set(["egg", "eggs", "butter", "milk", "wheat", "ham", "cream"])
                for text in texts {
                    let normalized = text.lowercased().replacingOccurrences(of: "_", with: " ")
                    for needle in needles {
                        let found = boundary.contains(needle)
                            ? normalized.range(of: "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: needle) + "(?![a-z0-9])", options: .regularExpression) != nil
                            : normalized.contains(needle)
                        if found { return "Conflicts with your \(value.replacingOccurrences(of: "_", with: " ")) \(allergy ? "allergy" : "diet"): contains \(needle)." }
                    }
                }
                return nil
            }
    }

    private static func dietKeywords(_ value: String) -> [String] {
        switch value {
        case "vegetarian": return meat + fish
        case "pescatarian": return meat
        case "vegan": return meat + fish + dairy + ["egg", "eggs", "honey"]
        case "dairy_free", "lactose_free": return dairy
        case "gluten_free": return ["wheat", "barley", "rye", "soy sauce", "seitan"]
        default: return []
        }
    }
}
