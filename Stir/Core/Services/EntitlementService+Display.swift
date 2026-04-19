// EntitlementService+Display
//
// Display-layer helpers on EntitlementService. These originally lived in
// `Features/Settings/SettingsRootView.swift` but the step-5 review
// flagged SRP concerns: co-locating EntitlementService extensions with
// its feature consumers spreads the service's surface area across the
// tree, making code-search for "all EntitlementService methods" miss
// the feature-file extensions. Moving here keeps the service's public
// API searchable in one subtree.
//
// `billingStateHelpText` is consumed by Settings' Plan & Billing card.
// It reads `tier`, `billingState`, `expiresAt` and renders a single
// sentence appropriate to the current account state.

import Foundation

extension EntitlementService {
    /// Shared `DateFormatter` for medium-style absolute dates (e.g. "Jun 12,
    /// 2026"). Previous inline instantiation allocated a fresh formatter on
    /// every computed-property evaluation — SwiftUI re-renders triggered
    /// by any `@Observable` property change cascaded into 3-5 DateFormatter
    /// allocations per Settings render. Static let caches the instance;
    /// Foundation's DateFormatter is documented as thread-safe for reads
    /// after configuration.
    fileprivate static let billingDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// Human-friendly sentence under the tier name in the Plan & Billing
    /// card. Covers all six `BillingState` values plus the `.free` tier
    /// shortcut.
    var billingStateHelpText: String {
        switch (tier, billingState) {
        case (.free, _):
            return "6 Dinner Solves a month. Upgrade for hands-free Cook Mode."
        case (_, .trial):
            if let expires = expiresAt {
                let daysLeft = max(0, Calendar.current.dateComponents([.day], from: Date(), to: expires).day ?? 0)
                let formatted = Self.billingDateFormatter.string(from: expires)
                if daysLeft > 0 {
                    return "Free trial — \(daysLeft) day\(daysLeft == 1 ? "" : "s") left. Renews \(formatted)."
                }
                return "Free trial ending today."
            }
            return "Free trial in progress."
        case (_, .active):
            if let expires = expiresAt {
                return "Active — renews \(Self.billingDateFormatter.string(from: expires))."
            }
            return "Active."
        case (_, .grace):
            return "Apple is retrying your payment."
        case (_, .cancelledActive):
            if let expires = expiresAt {
                return "Cancels \(Self.billingDateFormatter.string(from: expires))."
            }
            return "Cancels at end of current period."
        case (_, .expired):
            return "Expired. Resubscribe to regain Premium features."
        case (_, .none):
            return "Free."
        }
    }
}
