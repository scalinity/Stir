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
    /// bootstrap).
    ///
    /// **SCA-207 sunset trigger**: drop this fallback + flip
    /// `BootstrapResponse.Entitlements.standingPantryCap: Int?` →
    /// `Int` once v1.0 first beta build has been live for 14 days
    /// AND ≥99% of bootstrap responses carry the field per PostHog.
    /// Until then, keeping the table in lockstep with
    /// `STANDING_PANTRY_CAPS` in
    /// `Backend/supabase/functions/_shared/entitlements.ts` is a
    /// manual discipline — the `#warning` below ensures any code
    /// reader runs into a build-time reminder rather than silently
    /// syncing stale values.
    ///
    /// PaywallTrigger.subheadline still references the values inline
    /// because it's user-facing copy, not a programmatic constant —
    /// that copy stays in lockstep with the server values manually.
    #warning("SCA-100 transitional fallback table — sunset gated on SCA-207. Keep values in lockstep with Backend/supabase/functions/_shared/entitlements.ts STANDING_PANTRY_CAPS until then.")
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
