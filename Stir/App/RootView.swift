// RootView
//
// Phase-driven routing: loading → (onboarding | ready | offline | error).
// RootCoordinator is the Observable source of truth; every branch reads from
// coordinator.phase.

import SwiftUI

struct RootView: View {
    @Bindable var coordinator: RootCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingShareImport: PendingImport?

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
                TonightHomeView(coordinator: coordinator)

            case .offlineFallback:
                VStack(spacing: 0) {
                    OfflineBanner(onRetry: coordinator.retry)
                    TonightHomeView(coordinator: coordinator)
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
                    Task { await coordinator.refreshEntitlementsOnForeground() }
                }
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
            }
        }
        .onOpenURL { url in
            StirDeepLinkHandler.handle(url, coordinator: coordinator)
        }
        .fullScreenCover(item: $pendingShareImport) { pending in
            if let household = coordinator.household.profile {
                let vm = ImportViewModel(
                    household: household,
                    aiDispatch: coordinator.aiDispatch,
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
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
