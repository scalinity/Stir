// EntitlementTypes
//
// Typed enums for the three discriminants carried in the bootstrap response
// entitlements object. Matches the Postgres ENUMs defined in step 1 migrations.

import Foundation

enum Tier: String, Codable, Sendable, CaseIterable, Equatable {
    case free
    case premium
    case pro

    /// Standing-pantry-item cap per tier — CLAUDE.md §Tier-entitlements
    /// is the authoritative source. Centralized here so the value table
    /// has one home; `EntitlementService.rememberedPantryCap` routes
    /// through `effectiveTier` to apply the stale-snapshot demotion.
    /// PaywallTrigger.subheadline references the values inline because
    /// it's user-facing copy, not a programmatic constant.
    var rememberedPantryCap: Int {
        switch self {
        case .free:    return 25
        case .premium: return 250
        case .pro:     return 1000
        }
    }
}

enum BillingState: String, Codable, Sendable, CaseIterable, Equatable {
    case none
    case active
    case trial
    case grace
    case cancelledActive = "cancelled_active"
    case expired
}

enum FeatureKey: String, Codable, Sendable, CaseIterable, Hashable {
    case dinnerSolve = "dinner_solve"
    case voiceCookSession = "voice_cook_session"
    case recipeImport = "recipe_import"
}
