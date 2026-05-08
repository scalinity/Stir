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
    /// has one home.
    ///
    /// SCA-100: this constant table is now the FALLBACK path; the
    /// authoritative runtime value ships from the server on
    /// `entitlements.standing_pantry_cap` (bootstrap + config-bootstrap).
    /// `EntitlementService.rememberedPantryCap` prefers the server
    /// value and falls back to this table only when the field is
    /// absent (pre-SCA-100 server response or cold-launch-before-
    /// bootstrap). Once the SCA-100 deploy has been live for a release
    /// cycle and the iOS field is non-optional, this table can shrink
    /// to a "panic value" or be deleted.
    ///
    /// PaywallTrigger.subheadline still references the values inline
    /// because it's user-facing copy, not a programmatic constant —
    /// that copy stays in lockstep with the server values manually.
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
