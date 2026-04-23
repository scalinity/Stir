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
// Authorization status is surfaced at the top so users who've denied
// at the OS level see why toggling has no effect + a link to Settings.app.

import SwiftUI
import UserNotifications

struct NotificationPrefsView: View {
    @Environment(\.openURL) private var openURL
    @State private var prefs: NotificationPreferencesStore.Preferences =
        NotificationPreferencesStore.shared.preferences
    @State private var systemAuthorized: Bool = true

    private let store: NotificationPreferencesStore

    init(store: NotificationPreferencesStore = .shared) {
        self.store = store
    }

    var body: some View {
        List {
            if !systemAuthorized {
                Section {
                    systemAuthDisabledRow
                }
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
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.32)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.Stir.ink500)
            } footer: {
                Text("Server push for trial reminder + import completion require notification permission. Local reminders still fire when permission is off.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Stir.ink500)
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Color.Stir.paper50.ignoresSafeArea())
        .task {
            await refreshAuthorization()
            prefs = store.preferences
        }
    }

    // MARK: - Rows

    private func toggleRow(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.Stir.ink900)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Color.Stir.ink500)
                .lineLimit(2)
        }
    }

    private var systemAuthDisabledRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bell.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Stir.rust600)
                Text("Notifications are off")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.32)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.Stir.rust600)
            }
            Text("Stir needs notification permission to fire the reminders below. Turn it on in iOS Settings.")
                .font(.system(size: 13))
                .foregroundStyle(Color.Stir.ink700)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.Stir.ember600)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Permission status

    private func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        systemAuthorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral
    }
}
