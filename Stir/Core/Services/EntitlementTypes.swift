// EntitlementTypes
//
// Typed enums for the three discriminants carried in the bootstrap response
// entitlements object. Matches the Postgres ENUMs defined in step 1 migrations.

import Foundation

enum Tier: String, Codable, Sendable, CaseIterable, Equatable {
    case free
    case premium
    case pro
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
