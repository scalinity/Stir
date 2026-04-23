// RootView
//
// Phase-driven routing: loading → (onboarding | ready | offline | error).
// RootCoordinator is the Observable source of truth; every branch reads from
// coordinator.phase.

import SwiftUI

struct RootView: View {
    @Bindable var coordinator: RootCoordinator
    @Environment(\.scenePhase) private var scenePhase

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
                    OfflineBanner()
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
            if new == .active, coordinator.phase == .ready || coordinator.phase == .offlineFallback {
                Task { await coordinator.refreshEntitlementsOnForeground() }
            }
        }
        .onOpenURL { url in
            StirDeepLinkHandler.handle(url)
        }
    }
}

private struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.white)
            Text("Offline mode — using last known plan state. Pull to refresh.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange)
    }
}
