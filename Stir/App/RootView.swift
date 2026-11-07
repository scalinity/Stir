// RootView
//
// Phase-driven routing: loading → (onboarding | ready | offline | error).
// RootCoordinator is the Observable source of truth; every branch reads from
// coordinator.phase.
//
// Step 9 (2026-04-25): the post-launch shell switched from a single
// TonightHomeView push to a 3-tab `StirTabRoot` (Tonight / Saved /
// Settings) — Saved + Settings used to live inside Tonight as a list
// destination + a top-trailing toolbar push; both surfaces graduated
// to top-level tabs to match the mockup-03 reference image. The
// offline-fallback banner now floats above the tab shell rather than
// above Tonight specifically.

import SwiftUI
import OSLog

struct RootView: View {
    @Bindable var coordinator: RootCoordinator
    @Environment(\.scenePhase) private var scenePhase

    // User-selected color scheme override, written by the Appearance
    // card in `SettingsRootView`. Applied at the root via
    // `.preferredColorScheme(_:)` below so every surface (tabs,
    // sheets, full-screen covers, navigation chrome) honors the
    // choice with no per-screen wiring.
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        Group {
            switch coordinator.phase {
            case .loading:
                LoadingView()
                    .task { await coordinator.bootstrap() }

            case .configurationError(let message):
                ConfigurationErrorView(message: message, onRetry: coordinator.retry)

            case .onboarding:
                if let vm = coordinator.onboardingViewModel {
                    OnboardingRoot(
                        viewModel: vm,
                        onFinished: coordinator.handleOnboardingFinished,
                    )
                } else {
                    LoadingView()
                }

            case .ready:
                StirTabRoot(coordinator: coordinator)

            case .dataDeleted:
                DeletionCompleteView(state: coordinator.deletionState, onStartOver: coordinator.startOverAfterDeletion)

            case .offlineFallback:
                VStack(spacing: 0) {
                    OfflineBanner(onRetry: coordinator.retry)
                    StirTabRoot(coordinator: coordinator)
                }
            }
        }
        .environment(coordinator.entitlements)
        .environment(coordinator.cloudKit)
        .environment(coordinator.household)
        // Expose the coordinator so any feature-level view can call
        // `presentPaywall(_:)` without threading a callback through
        // every viewmodel. Keep reads to `@Environment(RootCoordinator.self)`
        // — direct mutation happens through the paywall methods, not
        // property writes.
        .environment(coordinator)
        // Paywall presentation is coordinator-driven; any view can set the
        // trigger and the overlay materializes here. `.fullScreenCover`
        // matches the spec's hard-paywall UX (blocks the underlying flow
        // until the user resolves the purchase decision).
        //
        // Success detection: we read `vm.didSucceed` (set at the moment
        // the state machine reached `.succeeded`) instead of inspecting
        // `coordinator.entitlements`, which lags by the webhook→Supabase
        // round-trip and would misclassify a just-purchased user as
        // "not succeeded" right after dismiss.
        .fullScreenCover(item: $coordinator.activePaywallTrigger) { trigger in
            let vm = coordinator.makePaywallViewModel(trigger: trigger)
            PaywallView(viewModel: vm)
                .onDisappear {
                    coordinator.dismissPaywall(wasSuccessful: vm.didSucceed)
                }
        }
        .onChange(of: scenePhase) { _, new in
            if new == .active {
                ReactivationScheduler.shared.cancel()
                if coordinator.phase == .ready || coordinator.phase == .offlineFallback {
                    Task { await coordinator.refreshEntitlementsIfStale() }
                }
                // SCA-99 / ADR 0035: drop the pantry tier-downgrade
                // banner once it ages past its 7-day TTL. No-op when
                // no banner is set or the banner is still fresh.
                coordinator.entitlements.dismissExpiredReconciliationBanner()
                // widget_added Retention funnel (spec §15). Widget process
                // writes a first-seen timestamp on its first getTimeline
                // fetch; we drain + emit exactly once per installation.
                if SharedStorage().drainWidgetFirstSeen() != nil {
                    PostHogClient.shared.capture(
                        .widgetAdded,
                        properties: StepSevenTelemetry.widgetAdded(source: "home_screen"),
                    )
                }
                drainPendingInputs()
                coordinator.reconcileImportedHouseholdsIfReady()
                coordinator.runImportRetentionMaintenance()
                // SCA-22: sweep expired ephemeral pantry rows on every
                // foreground. The "TODAY" badge would otherwise lie —
                // items scanned days ago would still display as today.
                // Combined with SCA-21's auto-consume on cook
                // completion, this makes pantry self-healing: matched
                // ingredients soft-delete at cook end; un-matched
                // ephemerals expire by the next morning's first open.
                // Phase guard mirrors the share-import drain — needs a
                // resolved household profile to scope to. Errors are
                // logged but never surfaced: pantry will retry the
                // sweep on the next foreground.
                if coordinator.phase == .ready,
                   let household = coordinator.household.profile {
                    do {
                        try coordinator.pantryItemRepository.softDeleteExpired(for: household)
                    } catch {
                        Logger.coreData.error(
                            "pantry softDeleteExpired failed: \(error.localizedDescription, privacy: .private)",
                        )
                    }
                    // SCA-97: tombstone reaper. `runIfDue` gates on a
                    // 7-day cadence stored in UserDefaults — repeated
                    // foreground transitions in the same window are
                    // free no-ops. Errors are caught + logged inside
                    // the reaper; this call site never throws. Sits
                    // alongside softDeleteExpired so both pantry-
                    // hygiene sweeps share the same trigger.
                    // SCA-300 W8: dispatched on a Task so the MainActor
                    // scenePhase hook doesn't block on the bg-context
                    // fetch + per-row delete + save (long-running users
                    // accumulating thousands of tombstones would
                    // otherwise stall the first foreground after a
                    // 24h cadence release).
                    Task { await coordinator.pantryTombstoneReaper.runIfDue(for: household) }
                }
                // SCA-430: one-shot legacy slug cleanup. Idempotent
                // by UserDefaults flag — repeat foregrounds after the
                // initial pass are free no-ops. Household-agnostic
                // (scans the entire local store, not scoped to one
                // profile), so this fires regardless of the
                // `coordinator.phase == .ready` gate; the migration
                // only writes to RecipeStep, which Core Data sets up
                // unconditionally on launch.
                Task { await coordinator.stepTextSlugCleanupMigration.runIfNeeded() }
            }
        }
        .onOpenURL { url in
            StirDeepLinkHandler.handle(url, coordinator: coordinator)
        }
        .onChange(of: coordinator.phase) { _, _ in drainPendingInputs() }
        .onReceive(NotificationCenter.default.publisher(for: .stirImportResultTapped)) { _ in
            drainPendingInputs()
        }
        .fullScreenCover(item: $coordinator.activeImport, onDismiss: coordinator.dismissImport) { presentation in
            if let household = coordinator.household.profile {
                let vm = coordinator.makeImportViewModel(for: household)
                ImportRoot(
                    viewModel: vm,
                    onDismiss: coordinator.dismissImport,
                    onCompleted: { _ in coordinator.dismissImport() }
                )
                .task {
                    switch presentation {
                    case .shared(let pending):
                        if let url = pending.url, !url.isEmpty { await vm.submitURL(url) }
                        else if let text = pending.text, !text.isEmpty { await vm.submitPastedText(text) }
                    case .recovery(let importID):
                        await vm.resume(importID: importID)
                    }
                }
            }
        }
        // User-selected color scheme override. `nil` (the `.system`
        // case) leaves SwiftUI's resolution to the iOS user-level
        // setting; `.light` / `.dark` force the override. Sits at the
        // root so the tab shell, modals, full-screen covers, and the
        // paywall fullScreenCover above all inherit the choice.
        .preferredColorScheme(appearance.colorScheme)
    }

    private func drainPendingInputs() {
        if let id = StirNotificationDelegate.shared.consumePendingImportID() {
            coordinator.requestImportResult(importID: id)
        } else {
            coordinator.drainPendingImportsIfReady()
        }
    }

}

// MARK: - StirTabRoot

/// Three-tab shell: Tonight (default), Saved, Settings.
///
/// Uses the system tab bar (Liquid Glass on iOS 26+, ADR 0037). `TabView`
/// preserves each tab's `NavigationStack` push history and `@State`
/// across selection changes, and the system bar insets every tab's safe
/// area so scrolling content clears it without manual padding.
///
/// Selection is driven by `coordinator.selectedTab` so Tonight's
/// bookmark-jump button (and any future deep-link that wants to
/// land on a specific tab) can flip tabs by writing one observable
/// property.
///
/// Saved + Settings are wrapped in their own `NavigationStack` so
/// each tab keeps its own back-stack across tab switches (per
/// platform convention). Tonight intentionally does NOT use a
/// NavigationStack — the screen title is rendered as scroll-view
/// content (mockup-03), not as a navigation-bar title, and it pushes
/// nothing (its flows are full-screen covers).
private struct StirTabRoot: View {
    @Bindable var coordinator: RootCoordinator

    var body: some View {
        TabView(selection: $coordinator.selectedTab) {
            TonightHomeView(coordinator: coordinator)
                .tabItem { Label { Text("Tonight") } icon: { Image.Stir.fork } }
                .tag(RootCoordinator.Tab.tonight)

            savedTab
                .tabItem { Label { Text("Saved") } icon: { Image.Stir.bookmark } }
                .tag(RootCoordinator.Tab.saved)

            NavigationStack {
                SettingsRootView()
            }
            .tabItem { Label { Text("Settings") } icon: { Image.Stir.settings } }
            .tag(RootCoordinator.Tab.settings)
        }
    }

    /// Saved tab body. Saved meals require a household profile — the
    /// `.ready` phase guarantees one (bootstrap eager-creates it), but
    /// guard defensively so an unexpected nil state shows a friendly
    /// empty rather than crashing.
    @ViewBuilder
    private var savedTab: some View {
        NavigationStack {
            if let household = coordinator.household.profile {
                SavedMealsView(
                    household: household,
                    aiDispatch: coordinator.aiDispatch,
                    repository: coordinator.cookingSessionRepository,
                    solveRepository: coordinator.solveRepository,
                )
            } else {
                VStack(spacing: CGFloat.Stir.space3) {
                    Image.Stir.bookmark
                        .font(.system(size: CGFloat.Stir.iconXl, weight: .regular))
                        .foregroundStyle(Color.Stir.ink300)
                    Text("Saved meals load once your kitchen is set up.")
                        .stirFont(.bodyMd)
                        .foregroundStyle(Color.Stir.ink500)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, CGFloat.Stir.space5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.Stir.paper50)
                .navigationTitle("Saved meals")
                .navigationBarTitleDisplayMode(.large)
            }
        }
    }
}

/// Persistent top banner for coordinator.phase == .offlineFallback.
///
/// Mockup 01 §"Offline fallback" — info-flavor banner (paper.200 bg,
/// ink.700 body, 44pt min height, 1pt ink.100 bottom border). Split
/// text surfaces "You're offline." as bold hook + "Saved meals and the
/// last scan still work." as reassurance. Inline Retry button re-runs
/// `coordinator.retry()` which re-probes reachability via a fresh
/// bootstrap attempt.
///
/// Note on copy vs spec: Spec §6 SYNC-01 message reads "iCloud Sync
/// isn't available. Stir will work on this device only for now." —
/// that wording targets the iCloud-specific failure mode. The mockup's
/// "You're offline. Saved meals and the last scan still work." targets
/// the general network-offline fallback, which is what the
/// `.offlineFallback` coordinator phase represents today. Kept the
/// mockup copy here; flagged in the turn-1 output contract that the
/// `.offlineFallback` phase currently covers both network and iCloud
/// offline in a single branch — a future task may split them per spec
/// §6 semantics.
private struct OfflineBanner: View {
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: CGFloat.Stir.space3 - 2) { // 10pt
            Image.Stir.syncOff
                .font(.system(size: CGFloat.Stir.iconSm))
                .foregroundStyle(Color.Stir.ink700)
                .accessibilityHidden(true)

            splitText
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRetry) {
                Text("Retry")
                    .stirFont(.labelMd)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.ember600)
                    .padding(.horizontal, CGFloat.Stir.space1)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Retry connection")
        }
        .padding(.leading, CGFloat.Stir.space4)
        .padding(.trailing, CGFloat.Stir.space2)
        .frame(minHeight: 44)
        .background(
            Color.Stir.paper200,
            ignoresSafeAreaEdges: [],
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.Stir.divider)
                .frame(height: 1)
        }
        // NOTE: no `.combine` here — the Retry button is an interactive
        // child. Combining flattened it into the static text label and
        // VoiceOver users couldn't activate retry. Let SwiftUI emit
        // the banner text + Retry as separate a11y elements.
        // Review finding C3 (FD1).
    }

    private var splitText: some View {
        (Text("You're offline.")
            .foregroundStyle(Color.Stir.ink900)
            .fontWeight(.semibold)
            + Text(" Saved meals and the last scan still work.")
            .foregroundStyle(Color.Stir.ink700))
            .stirFont(.bodySm)
    }
}

#Preview("OfflineBanner — light") {
    VStack(spacing: 0) {
        OfflineBanner(onRetry: {})
        Rectangle().fill(Color.Stir.paper50).frame(height: 200)
    }
    .frame(width: 390, height: 260)
    .preferredColorScheme(.light)
}

#Preview("OfflineBanner — dark") {
    VStack(spacing: 0) {
        OfflineBanner(onRetry: {})
        Rectangle().fill(Color.Stir.paper50).frame(height: 200)
    }
    .frame(width: 390, height: 260)
    .preferredColorScheme(.dark)
}
