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
    @State private var pendingShareImport: PendingImport?

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
                // Drain any share-extension-queued import. Two guards:
                //   (a) Only consume when phase == .ready. If the user
                //       shared during onboarding, coordinator.household.
                //       profile is nil and the cover body below would
                //       render empty @ViewBuilder — but consume* would
                //       have cleared the slot forever, producing an
                //       undismissable blank modal and losing the share
                //       (DB1-19). Re-checks on every foreground until
                //       onboarding completes.
                //   (b) User-scoped consume — drops the payload if its
                //       consumingUserKey mismatches the current
                //       identity (user signed into a different iCloud
                //       between share-time and re-open). Share-ext
                //       captures canonical_user_key at share time
                //       (SA2-10, CWE-345 defense).
                if coordinator.phase == .ready,
                   let pending = SharedStorage().consumePendingImport(
                       currentUserKey: SharedStorage().readCanonicalUserKey(),
                   ) {
                    pendingShareImport = pending
                }
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
        .fullScreenCover(item: $pendingShareImport) { pending in
            if let household = coordinator.household.profile {
                let importController = PersistenceController.shared
                let vm = ImportViewModel(
                    household: household,
                    aiDispatch: coordinator.aiDispatch,
                    importRepo: RecipeImportRepository(controller: importController),
                    controller: importController,
                )
                ImportRoot(
                    viewModel: vm,
                    onDismiss: { pendingShareImport = nil },
                    onCompleted: { _ in pendingShareImport = nil },
                )
                .task {
                    if let url = pending.url, !url.isEmpty {
                        await vm.submitURL(url)
                    } else if let text = pending.text, !text.isEmpty {
                        await vm.submitPastedText(text)
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
}

// MARK: - StirTabRoot

/// Three-tab shell: Tonight (default), Saved, Settings.
///
/// Visual: a custom floating-pill tab bar (`StirCustomTabBar`) replaces
/// the default iOS 26 glass `UITabBar`. Each tab's content carries
/// `.toolbar(.hidden, for: .tabBar)` so the system bar's chrome and
/// reserved safe-area space disappear; we then inject our pill bar
/// via `.safeAreaInset(edge: .bottom)` so each tab's content sees a
/// safe area that excludes the bar's height (no overlap on scroll
/// views) and the bar floats over the home-indicator gap. `TabView`
/// itself stays as the selection driver — it preserves per-tab
/// `NavigationStack` push history and per-tab `@State` across
/// selection changes (a `switch`-based replacement would lose both).
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
/// content (mockup-03), not as a navigation-bar title, and the
/// only push destinations were Saved + Settings (now their own tabs).
private struct StirTabRoot: View {
    @Bindable var coordinator: RootCoordinator

    var body: some View {
        // `@Bindable` exposes a Binding over `coordinator.selectedTab`
        // directly (`$coordinator.selectedTab`), so the manual
        // Binding(get:set:) closure isn't needed.
        TabView(selection: $coordinator.selectedTab) {
            TonightHomeView(coordinator: coordinator)
                .toolbar(.hidden, for: .tabBar)
                .tag(RootCoordinator.Tab.tonight)

            savedTab
                .toolbar(.hidden, for: .tabBar)
                .tag(RootCoordinator.Tab.saved)

            NavigationStack {
                SettingsRootView()
            }
            .toolbar(.hidden, for: .tabBar)
            .tag(RootCoordinator.Tab.settings)
        }
        // The custom bar is injected via `.safeAreaInset` rather than
        // `.overlay` so each tab's scrolling content reserves its own
        // bottom space — list content stays fully reachable and the
        // last row never sits under the bar.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StirCustomTabBar(selection: $coordinator.selectedTab)
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

// MARK: - StirCustomTabBar

/// Flat edge-to-edge tab bar — replaces iOS 26's glass `UITabBar`.
///
/// Visual grammar (mirrors the user-provided screenshot reference;
/// supersedes the earlier floating-pill draft after design review):
///   - Full-width `paper.50` background with NO top divider. Mockup-03
///     specified `border-top: 1px solid ink100`, but design review
///     2026-05-06 (SCA-20) preferred a clean tab bar — the bar reads
///     as a distinct surface via the `paper.50` fill against the
///     content area's own background, no hairline needed.
///   - Three equal-width cells inside (`maxWidth: .infinity`). Each
///     cell stacks an SF Symbol (~22pt) over a `.labelMd` label, both
///     in the same color so the active state reads as a clean color
///     flip with no sub-pill highlight.
///   - Active cell: `ember.600` icon + label. Inactive: `ink.500`
///     icon + label (matching color across icon and label is a
///     deliberate departure from the standard iOS bar's slightly-darker
///     icon — the screenshot reads as a single-tone column per cell).
///   - The Saved bookmark stays outlined regardless of active state
///     per the screenshot. (Earlier draft swapped to `bookmark.fill`
///     when active per mockup-03 JSX; the user-provided reference is
///     newer and overrides — outlined is the v1 visual.)
///
/// Reduce Motion: the selection write goes through `.stirAnimation`,
/// so the color flip is animated unless RM is on.
///
/// Accessibility: each cell is a `Button` with `accessibilityLabel(
/// "<Name> tab")` + `.isSelected` trait when active. VoiceOver reads
/// "Tonight tab, selected" — HIG-conventional for custom tab bars.
private struct StirCustomTabBar: View {
    @Binding var selection: RootCoordinator.Tab

    var body: some View {
        HStack(spacing: 0) {
            tabCell(.tonight, label: "Tonight", icon: Image.Stir.fork)
            tabCell(.saved, label: "Saved", icon: Image.Stir.bookmark)
            tabCell(.settings, label: "Settings", icon: Image.Stir.settings)
        }
        // 12pt top breathing room; −14pt bottom is intentional negative
        // padding that encroaches into the system home-indicator inset
        // so the labels sit visually close to the home-indicator pill.
        // Trade-off: the bar's measured frame is shorter than its
        // visual extent (`safeAreaInset` reserves the smaller value),
        // which is why the parent ScrollView's bottom padding is
        // bumped to 64pt to clear the gap. The two values are coupled
        // — change one, recheck the other. Locked at 12/−14 per design
        // review 2026-04-28.
        .padding(.top, CGFloat.Stir.space3)                // 12pt
        .padding(.bottom, -CGFloat.Stir.space3Half)        // −14pt
        .frame(maxWidth: .infinity)
        // `ignoresSafeAreaEdges: .bottom` extends the paper-50 fill
        // INTO the home-indicator strip so a tab whose content uses a
        // non-paper-50 background (Saved's List, Settings's grouped
        // List) doesn't show a colored seam below the bar.
        .background(Color.Stir.paper50, ignoresSafeAreaEdges: .bottom)
        .accessibilityElement(children: .contain)
    }

    private func tabCell(
        _ tab: RootCoordinator.Tab,
        label: String,
        icon: Image,
    ) -> some View {
        let isActive = selection == tab
        // Icon and label share one color per cell — single-tone column
        // per the screenshot. Active = ember; inactive = ink.500 (chosen
        // over ink.700 so the contrast against the paper.50 bar reads
        // as "quiet" rather than "bold").
        let color = isActive ? Color.Stir.ember600 : Color.Stir.ink500
        return Button {
            // Plain assignment — no `withStirAnimation` wrapping. The
            // observed-property write doesn't always carry the
            // animation transaction through `@Observable`'s tracking,
            // and even when it does, the cleaner pattern is to
            // animate the visible property locally via
            // `.stirAnimation(_:value:)` on the modifier chain below.
            // That approach is Reduce-Motion-aware out of the box.
            selection = tab
        } label: {
            VStack(spacing: CGFloat.Stir.space1) {              // 4pt
                icon
                    // justification: 22pt icon — between iconMd (20)
                    // and iconLg (28). One-off for the tab-bar visual
                    // weight; promote to a token if a second bar
                    // adopts the size.
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(color)
                Text(label)
                    .stirFont(.labelMd)
                    .foregroundStyle(color)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Reduce-Motion-aware color flip. `.stirAnimation` collapses
        // to identity under RM, so the selection cue is preserved
        // (color still changes) without animating the transition.
        .stirAnimation(.Stir.standard, value: isActive)
        .accessibilityLabel("\(label) tab")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

#Preview("StirCustomTabBar — light") {
    StatefulTabBarPreview()
        .padding(.bottom, 0)
        .frame(width: 390, height: 120)
        .background(Color.Stir.paper100)
        .preferredColorScheme(.light)
}

#Preview("StirCustomTabBar — dark") {
    StatefulTabBarPreview()
        .frame(width: 390, height: 120)
        .background(Color.Stir.paper100)
        .preferredColorScheme(.dark)
}

/// Mount-path preview — exercises `.safeAreaInset(edge: .bottom)`
/// over a non-`paper.50` background (mimics what the Saved tab's
/// List looks like underneath) AND simulates the system's
/// home-indicator inset via a faint gutter strip below the safe-
/// area-inset boundary. Two things become verifiable:
///   1. `ignoresSafeAreaEdges: .bottom` on the bar's bg correctly
///      fills the gutter (no colored seam from the white-ish List bg
///      bleeding through); and
///   2. With negative `.padding(.bottom, ...)` on the bar, the cell
///      content visibly overflows the inset's reserved frame INTO
///      the simulated gutter — the home-indicator-encroach trade-off
///      is visible at design-time rather than only on-device.
#Preview("StirCustomTabBar — over Saved-style background") {
    StatefulTabBarMountPreview()
        .preferredColorScheme(.light)
}

private struct StatefulTabBarPreview: View {
    @State private var tab: RootCoordinator.Tab = .tonight
    var body: some View {
        StirCustomTabBar(selection: $tab)
    }
}

private struct StatefulTabBarMountPreview: View {
    @State private var tab: RootCoordinator.Tab = .saved
    var body: some View {
        // White-ish List-style fill on top, to expose any bar-bg-vs-
        // content seam at the home-indicator boundary. Below the bar,
        // a faint gray gutter simulates iOS's reserved home-indicator
        // inset (which previews don't render on their own). The
        // gutter makes the bar's negative-padding visual encroach
        // visible at design-time — cell content (icons + labels)
        // should overflow into the gutter, while the bar's `paper.50`
        // bg should fill the gutter end-to-end (no white-bg seam).
        VStack(spacing: 0) {
            Color.white
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    StirCustomTabBar(selection: $tab)
                }
            Rectangle()
                .fill(Color.gray.opacity(0.15))
                .frame(height: 34)              // typical iPhone home-indicator inset
                .overlay(
                    Capsule()
                        .fill(Color.black.opacity(0.5))
                        .frame(width: 134, height: 5)
                        .padding(.bottom, 8),
                    alignment: .bottom,
                )
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
