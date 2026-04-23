// NotificationPrefsView
//
// Settings → Notifications. Per-toggle opt-in for each notification
// type Stir ships. Matches mockup 14's settings-list grammar: paper
// card surface, ember section headers, hairline dividers, tappable
// rows with right-aligned Toggles.
//
// Changing a toggle writes through NotificationPreferencesStore AND
// cancels any pending request in the disabled category (reactivation
// reminder especially — turning off should clear the in-flight
// notification, not just stop scheduling future ones).
//
// Authorization status distinguishes three presentation modes:
//   - .authorized / .provisional / .ephemeral: banner hidden.
//   - .notDetermined: "Request permission" prompt (iOS hasn't asked
//     yet). Pre-fix this was conflated with .denied — misleading,
//     the user had never seen the OS prompt (FD1-18 / W18).
//   - .denied / .restricted: "Open Settings" deeplink because the
//     in-app permission prompt can't re-request once denied.

import SwiftUI
import UserNotifications

struct NotificationPrefsView: View {
    @Environment(\.openURL) private var openURL
    @State private var prefs: NotificationPreferencesStore.Preferences =
        NotificationPreferencesStore.shared.preferences
    @State private var authorizationStatus: UNAuthorizationStatus = .authorized

    private let store: NotificationPreferencesStore

    init(store: NotificationPreferencesStore = .shared) {
        self.store = store
    }

    var body: some View {
        List {
            switch authorizationStatus {
            case .notDetermined:
                Section { notDeterminedRow }
            case .denied:
                Section { systemAuthDisabledRow }
            case .authorized, .provisional, .ephemeral:
                EmptyView()
            @unknown default:
                EmptyView()
            }
            Section {
                Toggle(isOn: $prefs.trialReminder) { toggleRow(
                    title: "Trial reminder",
                    subtitle: "Alerts you 2 days before your Premium trial ends.",
                ) }
                .onChange(of: prefs.trialReminder) { _, new in
                    store.setTrialReminder(new)
                }
                Toggle(isOn: $prefs.reactivation) { toggleRow(
                    title: "Cook reminder",
                    subtitle: "If you haven't cooked in a week, a friendly nudge.",
                ) }
                .onChange(of: prefs.reactivation) { _, new in
                    store.setReactivation(new)
                    if !new {
                        ReactivationScheduler.shared.cancel()
                    }
                }
                Toggle(isOn: $prefs.importCompletion) { toggleRow(
                    title: "Import completion",
                    subtitle: "Pings you when a long recipe import finishes.",
                ) }
                .onChange(of: prefs.importCompletion) { _, new in
                    store.setImportCompletion(new)
                }
            } header: {
                Text("Types")
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.ink500)
            } footer: {
                Text("Server push for trial reminder + import completion require notification permission. Local reminders still fire when permission is off.")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Color.Stir.paper50.ignoresSafeArea())
        .task {
            await refreshAuthorization()
            // Re-seed prefs from the store in case the in-line @State
            // default captured a stale snapshot (e.g. another screen
            // toggled a pref between view init and appearance).
            prefs = store.preferences
        }
    }

    // MARK: - Rows

    private func toggleRow(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .stirFont(.labelLg)
                .foregroundStyle(Color.Stir.ink900)
            Text(subtitle)
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink500)
                .lineLimit(2)
        }
    }

    /// Shown when iOS hasn't yet prompted the user for notification
    /// permission. Tap the button to trigger the OS prompt — if
    /// granted, `refreshAuthorization` picks up `.authorized` and the
    /// banner dismisses.
    private var notDeterminedRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Stir.ember600)
                Text("Enable notifications")
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.ember600)
            }
            Text("Stir uses notifications for trial reminders, cook nudges, and import completion. You haven't been asked yet — turn it on and Stir will prompt iOS next.")
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink700)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task {
                    _ = try? await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound, .badge])
                    await refreshAuthorization()
                }
            } label: {
                Text("Request permission")
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.ember600)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityHint("Prompts iOS for notification permission.")
        }
        .padding(.vertical, 4)
    }

    /// Shown when the user has explicitly denied notifications (or iOS
    /// has restricted them). Can't re-prompt from in-app; deeplink to
    /// Settings so the user can flip the toggle.
    private var systemAuthDisabledRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bell.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Stir.rust600)
                Text("Notifications are off")
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.rust600)
            }
            Text("Stir needs notification permission to fire the reminders below. Turn it on in iOS Settings.")
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink700)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Text("Open Settings")
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.ember600)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityHint("Opens iOS Settings to toggle notification permission.")
        }
        .padding(.vertical, 4)
    }

    // MARK: - Permission status

    private func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }
}
