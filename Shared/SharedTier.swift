// SharedTier
//
// Typed mirror of `entitlement_snapshots.tier` readable from every
// target in the App Group (main app, StirWidgets, StirShareExtension,
// AppIntents). Replaces hardcoded string comparisons like
// `tier == "premium" || tier == "pro"` which drift silently when tiers
// are renamed or added — CLAUDE.md bans those in view / intent / widget
// code.
//
// The backend canonical strings are lowercase: "free" | "premium" |
// "pro". SharedStorage.writeTier writes the raw string from
// `Tier.rawValue`; reads round-trip through this enum so an unknown
// value (e.g. a future "founder" tier written by a newer build) falls
// back to `nil` rather than silently treating it as free.

import Foundation

public enum SharedTier: String, Sendable, Codable, CaseIterable {
    case free
    case premium
    case pro

    /// True for any paid tier. Single decision site for "is this user
    /// entitled to a paid feature" so callers don't open-code the
    /// premium-or-pro check.
    public var isPaid: Bool {
        switch self {
        case .free: return false
        case .premium, .pro: return true
        }
    }
}
