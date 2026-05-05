// NotificationPrefsView
//
// Settings → Notifications. Per-toggle opt-in for each notification
// type Stir ships, rebuilt 2026-04-28 onto the custom design system
// to match `SettingsRootView` and `HouseholdPreferencesView`:
// paper50 background, principal-toolbar New York title, uppercase
// `labelEyebrow` section header, grouped `stirCard()` body with 1pt
// `ink100` internal dividers, 64pt bottom inset for the floating
// `StirCustomTabBar`. SF-Pro nav title + iOS-default `Form` chrome
// + green-tinted toggles all replaced.
//
// Trial-reminder toggle removed in the same change — the
// pre-rebuild file shipped a "Trial reminder" toggle here AND a
// trial-reminder card in `SettingsRootView`. The two were wired to
// different mechanisms (this page set a `NotificationPreferencesStore`
// flag, Settings called `TrialReminderScheduler` directly) which
// could disagree, and the feature itself has been retired. The
// `Preferences.trialReminder` field and `TrialReminderScheduler` are
// now dead code; removable in a follow-up cleanup.
//
// Authorization status distinguishes three presentation modes:
//   - .authorized / .provisional / .ephemeral: banner hidden.
//   - .notDetermined: "Request permission" prompt (iOS hasn't asked
//     yet). Pre-fix this was conflated with .denied — misleading,
//     the user had never seen the OS prompt (FD1-18 / W18).
//   - .denied: "Open Settings" deeplink because the in-app
//     permission prompt can't re-request once denied. (`UNAuthorizationStatus`
//     has no `.restricted` case despite older docs implying otherwise.)

import SwiftUI
import UserNotifications

struct NotificationPrefsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var prefs: NotificationPreferencesStore.Preferences =
        NotificationPreferencesStore.shared.preferences
    @State private var authorizationStatus: UNAuthorizationStatus = .authorized

    private let store: NotificationPreferencesStore

    init(store: NotificationPreferencesStore = .shared) {
        self.store = store
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                permissionBanner
                typesSection
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.top, CGFloat.Stir.space3)
            // Match `SettingsRootView` clearance for the −14pt-encroach
            // floating `StirCustomTabBar`. This view is pushed inside
            // the Settings tab's NavigationStack, so the floating bar
            // is still visible behind it.
            .padding(.bottom, CGFloat.Stir.space7 + CGFloat.Stir.space4) // 64pt
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Stir.paper50)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Notifications")
                    .stirFont(.displaySm)
                    .foregroundStyle(Color.Stir.textPrimary)
            }
        }
        .toolbarBackground(Color.Stir.paper50, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        // Persistence wiring — `.onChange` fires when @State `prefs`
        // mutates from the toggle's two-way binding. Doesn't fire on
        // initial mount, so the store-seeded values in `.task` don't
        // trigger spurious writes.
        .onChange(of: prefs.reactivation) { _, new in
            store.setReactivation(new)
            if !new {
                ReactivationScheduler.shared.cancel()
            }
        }
        .onChange(of: prefs.importCompletion) { _, new in
            store.setImportCompletion(new)
        }
        .task {
            await refreshAuthorization()
            // Re-seed prefs from the store in case the in-line @State
            // default captured a stale snapshot (e.g. another screen
            // toggled a pref between view init and appearance).
            prefs = store.preferences
        }
        // Re-check authorization on every return-to-foreground. Without
        // this, a user who taps "Open Settings", grants permission in
        // iOS Settings, and returns sees the "Notifications are off"
        // banner stay visible — `.task` only fires on first appearance,
        // and the SwiftUI view never disappears across an app
        // background/foreground cycle.
        .onChange(of: scenePhase) { _, new in
            if new == .active {
                Task { await refreshAuthorization() }
            }
        }
    }

    // MARK: - Permission banner

    @ViewBuilder
    private var permissionBanner: some View {
        switch authorizationStatus {
        case .notDetermined:
            notDeterminedCard
        case .denied:
            systemAuthDisabledCard
        case .authorized, .provisional, .ephemeral:
            EmptyView()
        @unknown default:
            EmptyView()
        }
    }

    /// First-run nudge — iOS hasn't been asked yet. Tap the button
    /// to trigger the OS prompt; on grant, `refreshAuthorization`
    /// picks up `.authorized` and the banner dismisses.
    private var notDeterminedCard: some View {
        permissionCard(
            // Plain `.notifications` (bell) — `.reminderBadge`'s
            // badge-dot variant means "a reminder is armed for a
            // future moment", which is the wrong semantic for "turn
            // notifications on at all".
            icon: Image.Stir.notifications,
            iconColor: Color.Stir.ember600,
            eyebrow: "Enable notifications",
            eyebrowColor: Color.Stir.ember600,
            body: "Stir uses notifications for cook nudges and import completion. You haven't been asked yet — turn it on and Stir will prompt iOS next.",
            buttonTitle: "Request permission",
            buttonHint: "Prompts iOS for notification permission.",
            fill: Color.Stir.paper200,
        ) {
            Task {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
                await refreshAuthorization()
            }
        }
    }

    /// Hard-denied — iOS won't let us prompt again from in-app, so
    /// deeplink to Settings. Amber tint signals "warning, action
    /// required" per Design-System.md §8.7 banner conventions.
    private var systemAuthDisabledCard: some View {
        permissionCard(
            icon: Image.Stir.notificationsOff,
            iconColor: Color.Stir.amber600,
            eyebrow: "Notifications are off",
            eyebrowColor: Color.Stir.amber600,
            body: "Stir needs notification permission to fire the reminders below. Turn it on in iOS Settings.",
            buttonTitle: "Open Settings",
            buttonHint: "Opens iOS Settings to toggle notification permission.",
            fill: Color.Stir.amber100,
        ) {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        }
    }

    /// Shared layout for both permission states. Both have the same
    /// shape (icon + eyebrow + body + action button); only colors,
    /// copy, and the action closure differ.
    private func permissionCard(
        icon: Image,
        iconColor: Color,
        eyebrow: String,
        eyebrowColor: Color,
        body: String,
        buttonTitle: String,
        buttonHint: String,
        fill: Color,
        action: @escaping () -> Void,
    ) -> some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            HStack(spacing: CGFloat.Stir.space2) {
                icon
                    .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(eyebrow)
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(eyebrowColor)
            }
            Text(body)
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.textSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                Text(buttonTitle)
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.ember600)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(buttonHint)
        }
        .padding(.horizontal, CGFloat.Stir.space3Half)
        .padding(.vertical, CGFloat.Stir.space3Half)
        .stirCard(fill: fill)
    }

    // MARK: - Types section

    private var typesSection: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            sectionEyebrow("Types")
            VStack(spacing: 0) {
                toggleRow(
                    title: "Cook reminder",
                    subtitle: "If you haven't cooked in a week, a friendly nudge.",
                    isOn: $prefs.reactivation,
                )
                rowDivider
                toggleRow(
                    title: "Import completion",
                    subtitle: "Pings you when a long recipe import finishes.",
                    isOn: $prefs.importCompletion,
                )
            }
            .stirCard()
            // Footnote sits OUTSIDE the card — same pattern as iOS
            // Form section footers, but rendered manually since
            // ScrollView doesn't have a footer slot. Aligned with
            // the eyebrow's 4pt horizontal inset for visual rhythm.
            Text("Server push for import completion requires notification permission. Local reminders still fire when permission is off.")
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.textTertiary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, CGFloat.Stir.space1)
                .padding(.top, CGFloat.Stir.space1)
        }
    }

    private func toggleRow(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>,
    ) -> some View {
        // `.center` HStack alignment matches mockup 14's toggle-row
        // pattern (`alignItems: 'center'` for every row carrying a
        // trailing Toggle). Shorter rows look balanced; longer
        // multi-line subtitles still center-align acceptably because
        // the subtitle's `.fixedSize` lets the row height grow with
        // the toggle naturally centered.
        HStack(alignment: .center, spacing: CGFloat.Stir.space3) {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space1 / 2) { // 2pt
                Text(title)
                    .stirFont(.labelLg)
                    .foregroundStyle(Color.Stir.textPrimary)
                Text(subtitle)
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: CGFloat.Stir.space2)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Color.Stir.ember600)
                .accessibilityLabel(title)
                .accessibilityHint(subtitle)
        }
        .padding(.horizontal, CGFloat.Stir.space3Half)
        .padding(.vertical, CGFloat.Stir.space3Half)
    }

    // MARK: - DS primitives

    private func sectionEyebrow(_ text: String) -> some View {
        Text(text)
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.textTertiary)
            .padding(.horizontal, CGFloat.Stir.space1)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.Stir.divider)
            .frame(height: 1)
            .padding(.leading, CGFloat.Stir.space3Half)
    }

    // MARK: - Permission status

    private func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }
}
