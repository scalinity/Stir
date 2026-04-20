// TonightHomeView
//
// Step-3 iteration:
//   - Scan Kitchen → presents ScanFlowRoot as fullScreenCover
//   - Import Recipe + Cook Saved remain disabled (step 4 + step 7)
//   - Respects the disable_scan_parse kill switch from the latest config
//     bootstrap response by rendering Scan Kitchen in a disabled state
//     with "Temporarily unavailable" copy.

import OSLog
import SwiftUI

struct TonightHomeView: View {
    let coordinator: RootCoordinator

    @Environment(EntitlementService.self) private var entitlements
    @State private var toastMessage: String?
    @State private var showScanFlow = false
    @State private var showSavedMeals = false
    @State private var resumableSession: CookingSession?
    @State private var recentCompleted: [CookingSession] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    resumableBanner
                    greeting
                    primaryActions
                    recentMealsSection
                    whyStirStrip
                }
                .padding()
            }
            .navigationTitle("Tonight")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsRootView() } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .overlay(alignment: .top) { toastOverlay }
            .fullScreenCover(isPresented: $showScanFlow) {
                ScanFlowRoot(
                    aiDispatch: coordinator.aiDispatch,
                    pantryRepo: coordinator.pantryItemRepository,
                    solveRepo: coordinator.solveRepository,
                    householdStore: coordinator.household,
                    entitlements: entitlements,
                )
            }
            .navigationDestination(isPresented: $showSavedMeals) {
                if let household = coordinator.household.profile {
                    SavedMealsView(
                        household: household,
                        aiDispatch: coordinator.aiDispatch,
                    )
                }
            }
            // Single unified fullScreenCover for ALL Cook Mode entry
            // paths. Multiple concurrent fullScreenCover modifiers on
            // the same view — even when at most one has a non-nil
            // item — trip iOS 18/26's "Currently, only presenting a
            // single sheet is supported" warning and queue later
            // presentations indefinitely. Consolidating to one cover
            // driven by a coordinator-owned enum avoids that entirely.
            .fullScreenCover(item: Binding(
                get: { coordinator.activeCookLaunch },
                set: { coordinator.activeCookLaunch = $0 },
            )) { launch in
                switch launch {
                case let .fresh(plan, household, _):
                    CookModeRoot(
                        recipePlan: plan,
                        household: household,
                        aiDispatch: coordinator.aiDispatch,
                        source: .solve,
                        onDismiss: {
                            coordinator.dismissCookMode()
                            Task { await refreshCookingState() }
                        },
                    )
                case let .resume(session):
                    if let plan = session.recipePlan,
                       let household = session.household {
                        CookModeRoot(
                            recipePlan: plan,
                            household: household,
                            aiDispatch: coordinator.aiDispatch,
                            source: .saved,
                            existingSession: session,
                            onDismiss: {
                                coordinator.dismissCookMode()
                                Task { await refreshCookingState() }
                            },
                        )
                    } else {
                        // Guard: CloudKit Nullify delete can leave a
                        // CookingSession with nil recipePlan/household
                        // (cross-device race). Without this branch
                        // fullScreenCover renders a blank undismissable
                        // modal. Mirrors DishPreview's fallback copy.
                        VStack(spacing: 12) {
                            Text("Couldn't load this dish")
                                .font(.headline)
                            Button("Close") {
                                coordinator.dismissCookMode()
                                Task { await refreshCookingState() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(40)
                    }
                }
            }
            .task { await refreshCookingState() }
        }
    }

    // MARK: - Sections

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What's for dinner?")
                .font(.title2.weight(.semibold))
            Text("Start from your kitchen, a saved meal, or a recipe you found.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var primaryActions: some View {
        VStack(spacing: 12) {
            scanKitchenButton
            primaryButton(
                systemImage: "square.and.arrow.down.on.square",
                title: "Import Recipe",
                subtitle: "Paste a URL or share from Safari to cook someone else's recipe.",
                tint: .purple,
                enabled: false,
                comingSoon: "Recipe import lands with Premium features (step 7).",
            )
            Button {
                showSavedMeals = true
            } label: {
                buttonRow(
                    systemImage: "bookmark.fill",
                    title: "Cook Saved",
                    subtitle: "One-tap replay for your favorites.",
                    tint: .indigo,
                    enabled: true,
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var scanKitchenButton: some View {
        let killed = scanIsKillSwitched
        return Button {
            if killed {
                toastMessage = "Kitchen scan is temporarily unavailable. Try a saved meal instead."
            } else {
                showScanFlow = true
            }
        } label: {
            buttonRow(
                systemImage: "camera.viewfinder",
                title: killed ? "Kitchen scan temporarily unavailable" : "Scan Kitchen",
                subtitle: killed
                    ? "We've paused scans while we investigate an issue."
                    : "Point at ingredients to get three dinner options.",
                tint: killed ? .secondary : .orange,
                enabled: !killed,
            )
        }
        .buttonStyle(.plain)
    }

    private func primaryButton(
        systemImage: String,
        title: String,
        subtitle: String,
        tint: Color,
        enabled: Bool,
        comingSoon: String,
    ) -> some View {
        Button {
            if !enabled { toastMessage = comingSoon }
        } label: {
            buttonRow(systemImage: systemImage, title: title, subtitle: subtitle, tint: tint, enabled: enabled)
        }
        .buttonStyle(.plain)
        // Keep the row tappable so VoiceOver/sighted users see a hint
        // surface; the accessibility hint conveys the coming-soon state
        // so the button isn't a bare dead control.
        .accessibilityHint(enabled ? "" : comingSoon)
    }

    private func buttonRow(
        systemImage: String,
        title: String,
        subtitle: String,
        tint: Color,
        enabled: Bool,
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(enabled ? tint : .secondary)
                .frame(width: 44, height: 44)
                .background(enabled ? tint.opacity(0.15) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(enabled ? Color.primary : .secondary)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var recentMealsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent meals")
                .font(.headline)
            if recentCompleted.isEmpty {
                Text("No recent meals yet — cook one to see it here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            } else {
                VStack(spacing: 10) {
                    ForEach(recentCompleted.prefix(5), id: \.id) { session in
                        recentMealRow(session: session)
                    }
                }
            }
        }
    }

    private func recentMealRow(session: CookingSession) -> some View {
        Button {
            // Cook Again — open a fresh Cook Mode on the same plan. If
            // session construction fails (e.g. RecipePlan nullified by
            // a CloudKit cross-device delete), surface a toast instead
            // of silently no-op'ing so the user knows the tap landed
            // (CA2-R7).
            if let fresh = makeFreshSessionIfPossible(from: session) {
                coordinator.resumeCookMode(fresh)
            } else {
                toastMessage = "Couldn't start this one again. Try from Saved or pick another meal."
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "fork.knife")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 40, height: 40)
                    .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.recipePlan?.title ?? "Untitled recipe")
                        .font(.subheadline.weight(.medium))
                    if let endedAt = session.endedAt {
                        Text(endedAt, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let rating = session.outcomeFeedback?.rating, rating > 0 {
                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { idx in
                                Image(systemName: idx <= Int(rating) ? "star.fill" : "star")
                                    .font(.caption2)
                                    .foregroundStyle(idx <= Int(rating) ? .yellow : .secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Rated \(Int(rating)) out of 5")
                    }
                }
                Spacer()
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Cook this again")
    }

    @ViewBuilder
    private var resumableBanner: some View {
        if let session = resumableSession, let plan = session.recipePlan {
            Button {
                coordinator.resumeCookMode(session)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Resume cooking")
                            .font(.subheadline.weight(.semibold))
                        Text(plan.title ?? "In progress")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Resume cooking \(plan.title ?? "in progress")")
        }
    }

    /// The "Cook Again" flow opens a NEW CookingSession so history is
    /// preserved. For step 4 we create it inside the repository before
    /// presenting. Returns nil when either relationship is missing
    /// (CloudKit nullified it cross-device) or the insert throws —
    /// caller surfaces a toast on nil (CA2-R7).
    private func makeFreshSessionIfPossible(from completed: CookingSession) -> CookingSession? {
        guard let plan = completed.recipePlan,
              let household = completed.household else { return nil }
        let repo = CookingSessionRepository()
        do {
            return try repo.createSession(on: household, for: plan, entryPoint: .saved)
        } catch {
            Logger.ui.error("Cook Again createSession failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @MainActor
    private func refreshCookingState() async {
        guard let household = coordinator.household.profile else { return }
        let repo = CookingSessionRepository()
        do {
            self.resumableSession = try repo.resumableSession(for: household)
            self.recentCompleted = try repo.recentCompletedSessions(for: household, limit: 5)
        } catch {
            Logger.ui.error("TonightHome refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var whyStirStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Why Stir works")
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                whyItem(icon: "fork.knife", text: "Your actual kitchen, not a generic recipe index.")
                whyItem(icon: "bolt.fill", text: "Three real dinners in under two minutes.")
                whyItem(icon: "hand.raised.fill", text: "Hard rules like allergies are never broken.")
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func whyItem(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text).font(.subheadline)
        }
    }

    // MARK: - Kill switch

    private var scanIsKillSwitched: Bool {
        entitlements.flagBool(forKey: "disable_scan_parse") ?? false
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastOverlay: some View {
        if let toastMessage {
            Text(toastMessage)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.85), in: Capsule())
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                // `.id(message)` forces `.task` to re-attach whenever the
                // toast text changes; without it, the 2-second timer from
                // the first tap would dismiss a message the user just
                // replaced with a second tap.
                .id(toastMessage)
                .task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { self.toastMessage = nil }
                }
        }
    }
}
