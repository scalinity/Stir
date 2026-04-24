// TonightHomeView
//
// Tonight Home — Stir's default control center (Spec §6 + mockup 03).
//
// DRIFT NOTE: Mockup 03's "Default state" shows a hero "Tonight's pick"
// card with a freshly-solved recipe waiting for the user to tap Start
// Cooking. That UX implies a "last solve, sitting here waiting"
// persisted state that's not in Spec §4 and not in current code —
// Solve flows directly into Cook Mode via user selection in
// ScanFlowRoot/DishPreview. Spec §6's Tonight Home row lists "Scan
// Kitchen, Import Recipe, Cook Saved" as user actions, not a pre-
// resolved hero card. Per source priority (spec > mockup), this view
// keeps the 3-action primary-surface structure from step-3 and
// migrates visuals to tokens rather than re-designing around a data
// concept that doesn't exist. Mockup 03's hero-card pattern is
// deferred pending a Spec §4 + §6 update that introduces a "last-
// solve" entity — tracked for a future task.
//
// What DOES map from mockup 03:
//   - `Tonight` display.lg title + bodyMd subtitle (greeting)
//   - `resumableBanner` rendered as an ember-tinted "Resume cooking"
//     card when a CookingSession is mid-flow — closest analogue to
//     the mockup's hero-card-with-CTA concept
//   - Empty/first-use state: dashed-border card with ember-tint camera
//     glyph tile + Scan Kitchen PrimaryButton + "Try the sample"
//     TextButton (matches mockup 03 §First-use empty)
//   - Recent meals list: token-migrated SavedMealCard-style rows
//   - "Why Stir works" strip: dropped in favor of the empty-state CTA
//     sufficiency (the why-strip was a step-3 placeholder)

import OSLog
import SwiftUI

struct TonightHomeView: View {
    let coordinator: RootCoordinator

    @Environment(EntitlementService.self) private var entitlements
    @State private var toastMessage: String?
    @State private var showSavedMeals = false
    @State private var resumableSession: CookingSession?
    @State private var recentCompleted: [CookingSession] = []
    @State private var activeModal: ActiveModal?

    enum ActiveModal: String, Identifiable {
        case scan
        case `import`
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                    greeting
                    resumableBanner
                    mainContent
                }
                .padding(.horizontal, CGFloat.Stir.screenMargin)
                .padding(.top, CGFloat.Stir.space2)
                .padding(.bottom, CGFloat.Stir.space5)
            }
            .background(Color.Stir.paper50)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsRootView() } label: {
                        Image.Stir.settings
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .overlay(alignment: .top) { toastOverlay }
            .onChange(of: coordinator.pendingDeepLinkScan) { _, new in
                guard new != nil, activeModal == nil else { return }
                activeModal = .scan
                coordinator.clearDeepLinkScan()
            }
            .fullScreenCover(item: $activeModal) { modal in
                switch modal {
                case .scan:
                    let capturedCoordinator = coordinator
                    ScanFlowRoot(
                        aiDispatch: coordinator.aiDispatch,
                        pantryRepo: coordinator.pantryItemRepository,
                        solveRepo: coordinator.solveRepository,
                        householdStore: coordinator.household,
                        entitlements: entitlements,
                        presentPaywall: { trigger in
                            capturedCoordinator.presentPaywall(trigger)
                        },
                    )
                case .import:
                    if let household = coordinator.household.profile {
                        let vm = ImportViewModel(
                            household: household,
                            aiDispatch: coordinator.aiDispatch,
                        )
                        ImportRoot(
                            viewModel: vm,
                            onDismiss: { activeModal = nil },
                            onCompleted: { _ in
                                activeModal = nil
                                Task { await refreshCookingState() }
                            },
                        )
                    }
                }
            }
            .navigationDestination(isPresented: $showSavedMeals) {
                if let household = coordinator.household.profile {
                    SavedMealsView(
                        household: household,
                        aiDispatch: coordinator.aiDispatch,
                    )
                }
            }
            .fullScreenCover(item: Binding(
                get: { coordinator.activeCookLaunch },
                set: { coordinator.activeCookLaunch = $0 },
            )) { launch in
                switch launch {
                case let .fresh(launch):
                    CookModeRoot(
                        recipePlan: launch.recipePlan,
                        household: launch.household,
                        aiDispatch: coordinator.aiDispatch,
                        source: .solve,
                        onDismiss: {
                            coordinator.dismissCookMode()
                            Task { await refreshCookingState() }
                        },
                    )
                case let .resume(session):
                    if !session.isDeleted,
                       let plan = session.recipePlan,
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
                        VStack(spacing: CGFloat.Stir.space3) {
                            Text("Couldn't load this dish")
                                .stirFont(.displaySm)
                                .foregroundStyle(Color.Stir.ink900)
                            PrimaryButton(title: "Close") {
                                coordinator.dismissCookMode()
                                Task { await refreshCookingState() }
                            }
                        }
                        .padding(CGFloat.Stir.space7 - 8)  // 40pt — hero error margin
                    }
                }
            }
            .task { await refreshCookingState() }
        }
    }

    // MARK: - Sections

    private var greeting: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
            Text("Tonight")
                .stirFont(.displayLg)
                .foregroundStyle(Color.Stir.ink900)
                .accessibilityAddTraits(.isHeader)

            Text(greetingSubtitle)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink500)
        }
    }

    private var greetingSubtitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        let weekday = formatter.string(from: Date())
        formatter.dateFormat = "h:mm a"
        let time = formatter.string(from: Date())
        return "\(weekday) · \(time)"
    }

    @ViewBuilder
    private var resumableBanner: some View {
        if let session = resumableSession, let plan = session.recipePlan {
            Button {
                coordinator.resumeCookMode(session)
            } label: {
                HStack(spacing: CGFloat.Stir.space3) {
                    Image.Stir.play
                        .font(.system(size: CGFloat.Stir.iconLg, weight: .semibold))
                        .foregroundStyle(Color.Stir.ember600)
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                                .fill(Color.Stir.ember100),
                        )

                    VStack(alignment: .leading, spacing: CGFloat.Stir.space1 / 2) {
                        Text("Resume cooking")
                            .stirFont(.labelLg)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.Stir.ink900)
                        Text(plan.title ?? "In progress")
                            .stirFont(.bodySm)
                            .foregroundStyle(Color.Stir.ink500)
                            .lineLimit(1)
                    }

                    Spacer()

                    Image.Stir.disclosure
                        .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                        .foregroundStyle(Color.Stir.ink300)
                }
                .padding(CGFloat.Stir.space3 + 2) // 14pt
                .background(
                    RoundedRectangle(cornerRadius: CGFloat.Stir.radiusCard, style: .continuous)
                        .fill(Color.Stir.ember100),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CGFloat.Stir.radiusCard, style: .continuous)
                        .strokeBorder(Color.Stir.ember600.opacity(0.4), lineWidth: 1),
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Resume cooking \(plan.title ?? "in progress")")
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if isFirstUse {
            firstUseEmpty
        } else {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                primaryActions
                recentMealsSection
            }
        }
    }

    /// Empty-state branch — user has never scanned, never cooked, no
    /// resumable session. Matches mockup 03 §First-use empty.
    private var firstUseEmpty: some View {
        VStack(spacing: CGFloat.Stir.space3 + 2) { // 14pt
            VStack(spacing: CGFloat.Stir.space3 + 2) {
                // Camera glyph tile — 80pt rounded ember-tint square
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.Stir.ember100)
                    Image.Stir.camera
                        .font(.system(size: 36, weight: .regular)) // justification: 36pt hero camera inside the 80pt tile — one-off per §4.1
                        .foregroundStyle(Color.Stir.ember600)
                }
                .frame(width: 80, height: 80)

                VStack(spacing: CGFloat.Stir.space2) {
                    Text("Let's see what you've got.")
                        .stirFont(.displayMd)
                        .foregroundStyle(Color.Stir.ink900)
                        .multilineTextAlignment(.center)

                    Text("Scan your fridge and pantry. I'll find three dinners you can make right now.")
                        .stirFont(.bodyMd)
                        .foregroundStyle(Color.Stir.ink500)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                }

                PrimaryButton(title: "Scan your kitchen") {
                    handleScanTap()
                }
                .padding(.top, CGFloat.Stir.space1 + 2) // 6pt

                TextButton(title: "Try the sample instead") {
                    toastMessage = "Sample scan is coming soon."
                }
            }
            .padding(.horizontal, CGFloat.Stir.space5)
            .padding(.vertical, CGFloat.Stir.space6 + 8) // 40pt
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        Color.Stir.ink300,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]),
                    ),
            )
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.Stir.paper100),
            )

            // Type-it-in secondary — currently routes to Import flow as a
            // reasonable "manual ingredient entry" proxy until a dedicated
            // type-it path lands.
            typeItInRow
        }
        .padding(.top, CGFloat.Stir.space3)
    }

    private var typeItInRow: some View {
        Button {
            activeModal = .import
        } label: {
            HStack(spacing: CGFloat.Stir.space3) {
                ZStack {
                    RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                        .fill(Color.Stir.paper200)
                    Text("Aa")
                        .font(.system(size: 18, weight: .semibold, design: .serif)) // justification: 18pt serif "Aa" glyph is a one-off typographic tile per §4.1
                        .foregroundStyle(Color.Stir.ink700)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: CGFloat.Stir.space1 / 2) {
                    Text("Type it in instead")
                        .stirFont(.labelLg)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.Stir.ink900)
                    Text("List what's in your kitchen by hand")
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.ink500)
                }

                Spacer()

                Image.Stir.disclosure
                    .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                    .foregroundStyle(Color.Stir.ink300)
            }
            .padding(CGFloat.Stir.space3 + 2) // 14pt
            .overlay(
                RoundedRectangle(cornerRadius: CGFloat.Stir.radiusCard, style: .continuous)
                    .strokeBorder(Color.Stir.divider, lineWidth: 1),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Type in your kitchen by hand")
    }

    private var primaryActions: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
            Text("Start from")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.ink500)

            VStack(spacing: CGFloat.Stir.space3) {
                scanKitchenButton
                actionRow(
                    icon: Image.Stir.imported,
                    title: "Import Recipe",
                    subtitle: "Paste a URL, pick a screenshot, or paste recipe text.",
                    action: { activeModal = .import },
                )
                actionRow(
                    icon: Image.Stir.bookmark,
                    title: "Cook Saved",
                    subtitle: "One-tap replay for your favorites.",
                    action: { showSavedMeals = true },
                )
            }
        }
    }

    private var scanKitchenButton: some View {
        let killed = scanIsKillSwitched
        return actionRow(
            icon: Image.Stir.scan,
            title: killed ? "Kitchen scan temporarily unavailable" : "Scan Kitchen",
            subtitle: killed
                ? "We've paused scans while we investigate an issue."
                : "Point at ingredients to get three dinner options.",
            enabled: !killed,
            action: {
                if killed {
                    toastMessage = "Kitchen scan is temporarily unavailable. Try a saved meal instead."
                } else {
                    activeModal = .scan
                }
            },
        )
    }

    private func handleScanTap() {
        if scanIsKillSwitched {
            toastMessage = "Kitchen scan is temporarily unavailable. Try a saved meal instead."
        } else {
            activeModal = .scan
        }
    }

    private func actionRow(
        icon: Image,
        title: String,
        subtitle: String,
        enabled: Bool = true,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: CGFloat.Stir.space3 + 2) { // 14pt
                ZStack {
                    RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                        .fill(enabled ? Color.Stir.ember100 : Color.Stir.paper200)
                    icon
                        .font(.system(size: CGFloat.Stir.iconMd + 4, weight: .semibold)) // justification: 24pt action-row icon — slightly larger than icon.md (20pt) so the primary-action tile reads at arm's length
                        .foregroundStyle(enabled ? Color.Stir.ember600 : Color.Stir.ink500)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: CGFloat.Stir.space1 / 2) {
                    Text(title)
                        .stirFont(.labelLg)
                        .fontWeight(.semibold)
                        .foregroundStyle(enabled ? Color.Stir.ink900 : Color.Stir.ink500)
                    Text(subtitle)
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.ink500)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: CGFloat.Stir.space2)

                Image.Stir.disclosure
                    .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                    .foregroundStyle(Color.Stir.ink300)
            }
            .padding(CGFloat.Stir.space3 + 2) // 14pt
            .background(
                RoundedRectangle(cornerRadius: CGFloat.Stir.radiusCard, style: .continuous)
                    .fill(Color.Stir.paper100),
            )
            .overlay(
                RoundedRectangle(cornerRadius: CGFloat.Stir.radiusCard, style: .continuous)
                    .strokeBorder(Color.Stir.divider, lineWidth: 1),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }

    @ViewBuilder
    private var recentMealsSection: some View {
        if !recentCompleted.isEmpty {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
                Text("Recent meals")
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.ink500)

                VStack(spacing: CGFloat.Stir.space2) {
                    ForEach(recentCompleted.prefix(5), id: \.id) { session in
                        recentMealRow(session: session)
                    }
                }
            }
        }
    }

    private func recentMealRow(session: CookingSession) -> some View {
        Button {
            if let fresh = makeFreshSessionIfPossible(from: session) {
                coordinator.resumeCookMode(fresh)
            } else {
                toastMessage = "Couldn't start this one again. Try from Saved or pick another meal."
            }
        } label: {
            HStack(alignment: .center, spacing: CGFloat.Stir.space3) {
                ZStack {
                    RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                        .fill(Color.Stir.paper200)
                    Image.Stir.fork
                        .font(.system(size: CGFloat.Stir.iconMd, weight: .regular))
                        .foregroundStyle(Color.Stir.ink700)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: CGFloat.Stir.space1 / 2) {
                    Text(session.recipePlan?.title ?? "Untitled recipe")
                        .stirFont(.labelLg)
                        .foregroundStyle(Color.Stir.ink900)
                        .lineLimit(1)

                    HStack(spacing: CGFloat.Stir.space2) {
                        if let endedAt = session.endedAt {
                            Text(endedAt, format: .relative(presentation: .named))
                                .stirFont(.bodySm)
                                .foregroundStyle(Color.Stir.ink500)
                        }
                        if let rating = session.outcomeFeedback?.rating, rating > 0 {
                            ratingStars(rating: Int(rating))
                        }
                    }
                }

                Spacer()

                Image.Stir.refresh
                    .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                    .foregroundStyle(Color.Stir.ink300)
            }
            .padding(CGFloat.Stir.space3)
            .background(
                RoundedRectangle(cornerRadius: CGFloat.Stir.radiusCard, style: .continuous)
                    .fill(Color.Stir.paper100),
            )
            .overlay(
                RoundedRectangle(cornerRadius: CGFloat.Stir.radiusCard, style: .continuous)
                    .strokeBorder(Color.Stir.divider, lineWidth: 1),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(session.recipePlan?.title ?? "Untitled recipe")
        .accessibilityHint("Cook this again")
    }

    private func ratingStars(rating: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(1 ... 5, id: \.self) { idx in
                Image(systemName: idx <= rating ? "star.fill" : "star")
                    .font(.system(size: 11)) // justification: 11pt micro-star scale matches mockup's recent-meal rating row
                    .foregroundStyle(idx <= rating ? Color.Stir.ember600 : Color.Stir.ink300)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rated \(rating) of 5")
    }

    // MARK: - State helpers

    private var isFirstUse: Bool {
        resumableSession == nil && recentCompleted.isEmpty
    }

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

    // MARK: - Kill switch

    private var scanIsKillSwitched: Bool {
        entitlements.flagBool(forKey: "disable_scan_parse") ?? false
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastOverlay: some View {
        if let toastMessage {
            Text(toastMessage)
                .stirFont(.bodySm)
                .fontWeight(.medium)
                .foregroundStyle(Color.Stir.paper50)
                .padding(.horizontal, CGFloat.Stir.space3 + 2) // 14pt
                .padding(.vertical, CGFloat.Stir.space2 + 2)   // 10pt
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.Stir.ink900.opacity(0.85)),
                )
                .padding(.top, CGFloat.Stir.space3)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(toastMessage)
                .task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { self.toastMessage = nil }
                }
        }
    }
}
