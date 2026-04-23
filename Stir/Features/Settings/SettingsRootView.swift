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
    @State private var restoreToast: StirToastPayload?

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
            notificationsSection
            householdSection
            syncSection
            aboutSection
            versionSection
            #if DEBUG
            debugSection
            #endif
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .stirToast($restoreToast)
    }

    #if DEBUG
    /// DEBUG-only surface for validation-harness flows (D.1). Hidden
    /// from release builds via the `#if DEBUG` guard on both the
    /// section and the destination view file.
    private var debugSection: some View {
        Section("Debug") {
            NavigationLink(destination: VoiceDiagnosticsView()) {
                Label("Voice Diagnostics", systemImage: "waveform.badge.magnifyingglass")
            }
        }
    }
    #endif

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
            VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
                Text(entitlements.tier.displayName)
                    .stirFont(.displaySm)
                    .foregroundStyle(Color.Stir.textPrimary)
                Text(entitlements.billingStateHelpText)
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.textTertiary)
            }
            Spacer()
            // Free uses `sparkles` (not `star`) to keep `star` reserved
            // for the favorites metaphor across the app. Paid tiers get
            // the crown, colored ember to match the mockup's premium-
            // emphasis hue rather than the gold/yellow SF default.
            Image(systemName: entitlements.tier == .free ? "sparkles" : "crown.fill")
                .foregroundStyle(
                    entitlements.tier == .free
                        ? Color.Stir.textTertiary
                        : Color.Stir.ember600,
                )
        }
    }

    // Free / expired-fallback: prompt to upgrade.
    private var freeFooter: some View {
        Button {
            coordinator.presentPaywall(.settingsUpgrade)
        } label: {
            Label {
                Text("Upgrade to Premium")
                    .stirFont(.labelLg)
            } icon: {
                Image.Stir.sparkles
            }
            .foregroundStyle(Color.Stir.ember600)
        }
    }

    // Active / trial: show manage link + trial conversion date when applicable.
    private var activeFooter: some View {
        Button {
            openManageSubscriptions()
        } label: {
            Label {
                Text("Manage subscription")
                    .stirFont(.labelLg)
            } icon: {
                Image(systemName: "person.crop.circle.badge.checkmark")
            }
            .foregroundStyle(Color.Stir.ember600)
        }
    }

    // Grace: billing retry in progress. Show alert + manage link to fix payment.
    private var graceFooter: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            HStack(spacing: CGFloat.Stir.space2) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.Stir.amber600)
                Text("Apple couldn't renew your subscription. Update billing to keep Premium features.")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.textSecondary)
            }
            Button {
                openManageSubscriptions()
            } label: {
                Label {
                    Text("Update payment method")
                        .stirFont(.labelLg)
                } icon: {
                    Image(systemName: "creditcard")
                }
                .foregroundStyle(Color.Stir.ember600)
            }
        }
    }

    // Cancelled but still active until period end. Single CTA —
    // earlier version had "Keep Premium" + "Manage" both linking to the
    // same apps.apple.com URL, which is redundant.
    private var cancelledFooter: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            if let expires = entitlements.expiresAt {
                Text("Cancels \(expires.formatted(date: .abbreviated, time: .omitted)). You still have Premium until then.")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.textTertiary)
            }
            Button {
                openManageSubscriptions()
            } label: {
                Label {
                    Text("Keep Premium")
                        .stirFont(.labelLg)
                } icon: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.Stir.ember600)
        }
    }

    // Expired: full win-back CTA.
    private var expiredFooter: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            Text("Your Premium plan ended. Start again?")
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.textTertiary)
            Button {
                coordinator.presentPaywall(.settingsUpgrade)
            } label: {
                Label {
                    Text("Resubscribe")
                        .stirFont(.labelLg)
                } icon: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.Stir.ember600)
        }
    }

    // Restore Purchases — always visible, even for paid users.
    private var restoreButton: some View {
        Button {
            Task { await restore() }
        } label: {
            HStack {
                Label {
                    Text("Restore purchases")
                        .stirFont(.labelLg)
                } icon: {
                    Image(systemName: "arrow.down.circle")
                }
                .foregroundStyle(Color.Stir.ember600)
                Spacer()
                if isRestoring {
                    ProgressView()
                        .tint(Color.Stir.ember600)
                }
            }
        }
        .disabled(isRestoring)
    }

    // MARK: - Trial reminder toggle

    private var trialReminderSection: some View {
        Section {
            Toggle(isOn: $trialReminderEnabled) {
                VStack(alignment: .leading, spacing: CGFloat.Stir.space1 / 2) { // 2pt — tight title/subtitle pairing
                    Text("Trial ending reminder")
                        .stirFont(.labelLg)
                        .foregroundStyle(Color.Stir.textPrimary)
                    Text("Get a notification 2 days before your trial ends.")
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.textTertiary)
                }
            }
            .tint(Color.Stir.ember600)
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

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section {
            NavigationLink(destination: NotificationPrefsView()) {
                Label("Notifications", systemImage: "bell")
            }
        }
    }

    // MARK: - Household

    private var householdSection: some View {
        Section {
            NavigationLink(destination: HouseholdPreferencesView()) {
                Label {
                    Text("Household preferences")
                        .stirFont(.labelLg)
                        .foregroundStyle(Color.Stir.textPrimary)
                } icon: {
                    Image.Stir.profile
                        .foregroundStyle(Color.Stir.ember600)
                }
            }
        } header: {
            Text("Household")
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        // Status dot uses sage (success) / amber (warning) — Design-System
        // §3 semantic pairing. Previous version used `.green`/`.orange`
        // which reads too-saturated against the warm paper palette.
        Section {
            HStack(spacing: CGFloat.Stir.space3) {
                Circle()
                    .fill(cloudKit.isAvailable ? Color.Stir.sage600 : Color.Stir.amber600)
                    .frame(width: CGFloat.Stir.space3 - 2, height: CGFloat.Stir.space3 - 2) // 10pt dot
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: CGFloat.Stir.space1 / 2) {
                    Text(cloudKit.isAvailable ? "iCloud synced" : "Local only")
                        .stirFont(.labelLg)
                        .foregroundStyle(Color.Stir.textPrimary)
                    Text(cloudKit.isAvailable ? "Your kitchen syncs across your devices."
                                              : "iCloud Sync isn't available. Stir will work on this device only for now.")
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.textTertiary)
                }
            }
            .accessibilityElement(children: .combine)
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
                .stirFont(.labelLg)
                .foregroundStyle(Color.Stir.ember600)
            Link("Terms of Service", destination: URL(string: "https://stir.app/terms")!)
                .stirFont(.labelLg)
                .foregroundStyle(Color.Stir.ember600)
            Link("Support", destination: URL(string: "mailto:scalinity.ai@gmail.com")!)
                .stirFont(.labelLg)
                .foregroundStyle(Color.Stir.ember600)
        } header: {
            Text("About")
        }
    }

    private var versionSection: some View {
        Section {
            LabeledContent {
                let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
                Text("\(short) (\(build))")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.textTertiary)
            } label: {
                Text("Build")
                    .stirFont(.bodyMd)
                    .foregroundStyle(Color.Stir.textSecondary)
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
        let payload: StirToastPayload
        switch outcome {
        case .restored:
            payload = StirToastPayload(id: UUID(), message: "Restored. Welcome back.", kind: .success)
        case .nothingToRestore:
            payload = StirToastPayload(id: UUID(), message: "No active purchase to restore.", kind: .info)
        case .failed(let e):
            payload = StirToastPayload(id: UUID(), message: "Couldn't restore: \(e.userFacingMessage)", kind: .failed)
        }

        // Race guard: a second tap within 2.5s would cause the first
        // task's clear to dismiss the second toast prematurely. StirToastPayload
        // carries a UUID id — only clear if the currently-presented toast
        // is still the one this task set.
        let myID = payload.id
        restoreToast = payload
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        if restoreToast?.id == myID {
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
