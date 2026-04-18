// SettingsRootView
//
// Settings shell per spec §6:
//   - Plan & Billing card (tier + billing_state surfaced from EntitlementService)
//   - Household Preferences → full edit of diet / equipment / servings / units
//   - Sync Status row (CloudKit availability + SYNC-01 state)
//   - Privacy Policy + Terms of Service placeholder links
//   - Version info

import SwiftUI

struct SettingsRootView: View {
    @Environment(EntitlementService.self) private var entitlements
    @Environment(CloudKitAvailabilityStore.self) private var cloudKit

    var body: some View {
        List {
            planBillingSection
            householdSection
            syncSection
            aboutSection
            versionSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Plan & Billing

    private var planBillingSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entitlements.tier.displayName)
                        .font(.headline)
                    Text(entitlements.billingStateHelpText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: entitlements.tier == .free ? "star" : "crown.fill")
                    .foregroundStyle(
                        entitlements.tier == .free
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(.yellow),
                    )
            }

            if entitlements.showBillingGraceBanner {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Apple couldn't renew your subscription. Update billing to keep Premium features.")
                        .font(.footnote)
                }
            }
        } header: {
            Text("Plan & Billing")
        }
    }

    // MARK: - Household

    private var householdSection: some View {
        Section {
            NavigationLink(destination: HouseholdPreferencesView()) {
                Label("Household preferences", systemImage: "person.crop.circle")
            }
        } header: {
            Text("Household")
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section {
            HStack(spacing: 10) {
                Circle()
                    .fill(cloudKit.isAvailable ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cloudKit.isAvailable ? "iCloud synced" : "Local only")
                        .font(.headline)
                    Text(cloudKit.isAvailable ? "Your kitchen syncs across your devices."
                                              : "iCloud Sync isn't available. Stir will work on this device only for now.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Sync")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            // Privacy + ToS are placeholder destinations in step 2. Real
            // hosted URLs land before beta (step 9).
            Link("Privacy Policy", destination: URL(string: "https://stir.app/privacy")!)
            Link("Terms of Service", destination: URL(string: "https://stir.app/terms")!)
            Link("Support", destination: URL(string: "mailto:scalinity.ai@gmail.com")!)
        } header: {
            Text("About")
        }
    }

    private var versionSection: some View {
        Section {
            LabeledContent("Build") {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    .foregroundStyle(.secondary)
                    + Text(" (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"))")
                        .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Display helpers on typed enums

extension Tier {
    var displayName: String {
        switch self {
        case .free:    return "Free"
        case .premium: return "Premium"
        case .pro:     return "Pro"
        }
    }
}

extension EntitlementService {
    /// Human-friendly sentence under the tier name in the Plan & Billing card.
    var billingStateHelpText: String {
        switch (tier, billingState) {
        case (.free, _):
            return "6 Dinner Solves a month. Upgrade for hands-free Cook Mode."
        case (_, .trial):
            if let expires = expiresAt {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                return "Free trial — renews \(formatter.string(from: expires))."
            }
            return "Free trial in progress."
        case (_, .active):
            if let expires = expiresAt {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                return "Active — renews \(formatter.string(from: expires))."
            }
            return "Active."
        case (_, .grace):
            return "Apple is retrying your payment."
        case (_, .cancelledActive):
            if let expires = expiresAt {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                return "Cancels \(formatter.string(from: expires))."
            }
            return "Cancels at end of current period."
        case (_, .expired):
            return "Expired. Resubscribe to regain Premium features."
        case (_, .none):
            return "Free."
        }
    }
}
