// SettingsRootView
//
// Settings shell per spec §6:
//   - Plan & Billing card — tier + billing_state, upgrade/manage CTAs,
//     Restore Purchases, trial-reminder toggle
//   - Household Preferences → full edit of diet / equipment / servings / units
//   - Sync Status row (CloudKit availability + SYNC-01 state)
//   - Privacy Policy + Terms of Service placeholder links
//   - Version info
//
// Step 5 additions:
//   - Trial + expiration + grace + cancelled + expired states each render
//     distinct copy + CTAs.
//   - Manage Subscription deep-link to apps.apple.com/account/subscriptions.
//   - Restore Purchases button emits `restore_purchases_tapped` with
//     origin="settings".
//   - Trial-reminder 2-day-before notification toggle (Premium trial only).

import SwiftUI
import UIKit
import UserNotifications

struct SettingsRootView: View {
    @Environment(EntitlementService.self) private var entitlements
    @Environment(CloudKitAvailabilityStore.self) private var cloudKit
    @Environment(RootCoordinator.self) private var coordinator

    @State private var isRestoring = false
    @State private var restoreToast: SettingsToast?
    @State private var restoreToastID = UUID()

    /// User setting for the trial reminder. Hydrated on appear from the
    /// actual pending `UNNotificationRequest` state so a user who
    /// previously turned the toggle off sees it off again — earlier
    /// version hardcoded `true` and silently re-scheduled on nav
    /// return.
    @State private var trialReminderEnabled: Bool = true

    var body: some View {
        List {
            planBillingSection
            if isTrialActive {
                trialReminderSection
            }
            householdSection
            syncSection
            aboutSection
            versionSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let toast = restoreToast {
                Text(toast.message)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Plan & Billing

    private var planBillingSection: some View {
        Section {
            planHeader

            switch (entitlements.tier, entitlements.billingState) {
            case (.free, _):
                freeFooter
            case (_, .expired):
                expiredFooter
            case (_, .grace):
                graceFooter
            case (_, .cancelledActive):
                cancelledFooter
            case (_, .trial):
                activeFooter  // trial treated as "active" in UI
            case (_, .active):
                activeFooter
            case (_, .none):
                // Paid tier somehow with billing_state=none — defensive, treat as free.
                freeFooter
            }

            restoreButton
        } header: {
            Text("Plan & Billing")
        }
    }

    private var planHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(entitlements.tier.displayName)
                    .font(.headline)
                Text(entitlements.billingStateHelpText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Free uses `sparkles` (not `star`) to keep `star` reserved
            // for the favorites metaphor across the app. Paid tiers get
            // the crown.
            Image(systemName: entitlements.tier == .free ? "sparkles" : "crown.fill")
                .foregroundStyle(
                    entitlements.tier == .free
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(.yellow),
                )
        }
    }

    // Free / expired-fallback: prompt to upgrade.
    private var freeFooter: some View {
        Button {
            coordinator.presentPaywall(.settingsUpgrade)
        } label: {
            Label("Upgrade to Premium", systemImage: "sparkles")
        }
    }

    // Active / trial: show manage link + trial conversion date when applicable.
    private var activeFooter: some View {
        Button {
            openManageSubscriptions()
        } label: {
            Label("Manage subscription", systemImage: "person.crop.circle.badge.checkmark")
        }
    }

    // Grace: billing retry in progress. Show alert + manage link to fix payment.
    private var graceFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("Apple couldn't renew your subscription. Update billing to keep Premium features.")
                    .font(.footnote)
            }
            Button {
                openManageSubscriptions()
            } label: {
                Label("Update payment method", systemImage: "creditcard")
            }
        }
    }

    // Cancelled but still active until period end. Single CTA —
    // earlier version had "Keep Premium" + "Manage" both linking to the
    // same apps.apple.com URL, which is redundant.
    private var cancelledFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let expires = entitlements.expiresAt {
                Text("Cancels \(expires.formatted(date: .abbreviated, time: .omitted)). You still have Premium until then.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                openManageSubscriptions()
            } label: {
                Label("Keep Premium", systemImage: "arrow.uturn.backward.circle")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // Expired: full win-back CTA.
    private var expiredFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your Premium plan ended. Start again?")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                coordinator.presentPaywall(.settingsUpgrade)
            } label: {
                Label("Resubscribe", systemImage: "arrow.clockwise.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // Restore Purchases — always visible, even for paid users.
    private var restoreButton: some View {
        Button {
            Task { await restore() }
        } label: {
            HStack {
                Label("Restore purchases", systemImage: "arrow.down.circle")
                Spacer()
                if isRestoring { ProgressView() }
            }
        }
        .disabled(isRestoring)
    }

    // MARK: - Trial reminder toggle

    private var trialReminderSection: some View {
        Section {
            Toggle(isOn: $trialReminderEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trial ending reminder")
                    Text("Get a notification 2 days before your trial ends.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: trialReminderEnabled) { _, newValue in
                Task {
                    if newValue, let expires = entitlements.expiresAt {
                        await TrialReminderScheduler.shared.ensureReminder(expiresAt: expires)
                    } else {
                        TrialReminderScheduler.shared.cancel()
                    }
                }
            }
            .task { await loadTrialReminderState() }
        } header: {
            Text("Trial")
        }
    }

    private var isTrialActive: Bool {
        entitlements.billingState == .trial && entitlements.expiresAt != nil
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
            // Privacy + ToS are placeholder destinations; hosted URLs
            // land before beta (step 9).
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
                // Single .secondary foreground (previously mixed .secondary +
                // .tertiary which read as two different levels of importance
                // for what is one value).
                let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
                Text("\(short) (\(build))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func openManageSubscriptions() {
        // Apple-provided deep link. Fails silently on simulator w/o App Store.
        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
            UIApplication.shared.open(url)
        }
    }

    @MainActor
    private func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }

        // Build a VM only to reuse `restore()` telemetry + refresh wiring.
        // The .settingsUpgrade trigger is used as the viewed context but
        // no paywall_viewed event fires since we don't call load().
        let vm = coordinator.makePaywallViewModel(trigger: .settingsUpgrade)
        let outcome = await vm.restore(origin: .settings)
        let toast: SettingsToast
        switch outcome {
        case .restored:         toast = .init(message: "Restored. Welcome back.")
        case .nothingToRestore: toast = .init(message: "No active purchase to restore.")
        case .failed(let e):    toast = .init(message: "Couldn't restore: \(e.userFacingMessage)")
        }

        // Race guard: a second tap within 2.5s would cause the first
        // task's clear to dismiss the second toast prematurely. Track
        // an ID; only the matching task is allowed to clear.
        let myID = UUID()
        restoreToastID = myID
        restoreToast = toast
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        if restoreToastID == myID {
            restoreToast = nil
        }
    }

    /// Hydrate `trialReminderEnabled` from the actual pending-notification
    /// state. Runs once on appear so a user who toggled it off previously
    /// sees the toggle reflect that.
    @MainActor
    private func loadTrialReminderState() async {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let hasReminder = pending.contains { $0.identifier == "stir.trial.reminder.2d" }
        trialReminderEnabled = hasReminder
    }
}

private struct SettingsToast: Equatable {
    let message: String
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

// `billingStateHelpText` lives in `Core/Services/EntitlementService+Display.swift`
// per the step-5 review (SRP: EntitlementService extensions belong with the
// service, not in feature files).
