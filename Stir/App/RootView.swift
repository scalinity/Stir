// RootView
//
// Phase-driven routing: loading → (onboarding | ready | offline | error).
// RootCoordinator is the Observable source of truth; every branch reads from
// coordinator.phase.

import SwiftUI

struct RootView: View {
    @Bindable var coordinator: RootCoordinator

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
