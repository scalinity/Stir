// OnboardingRoot
//
// NavigationStack + routing wrapper. Instantiated by RootCoordinator when
// HouseholdProfile.onboardingCompleted == false (commit 9).
//
// onFinished: fires after the final step commits to Core Data. RootCoordinator
// swaps to TonightHome.

import SwiftUI

struct OnboardingRoot: View {
    @Bindable var viewModel: OnboardingViewModel
    let onFinished: () -> Void

    @State private var path: [OnboardingRoute] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView(
                onTryIt: {
                    path.append(.setupPreferences)
                },
                onSeeSample: {
                    // Step-2 stub — sample path lands in step 3. For now,
                    // skip straight to Tonight Home with a shell profile.
                    Task {
                        do {
                            try viewModel.completeOnboarding()
                            onFinished()
                        } catch {
                            errorMessage = "Something went wrong. Please try again."
                        }
                    }
                },
            )
            .navigationDestination(for: OnboardingRoute.self) { route in
                switch route {
                case .setupPreferences:
                    SetupPreferencesView(
                        viewModel: viewModel,
                        onContinue: {
                            Task {
                                do {
                                    try viewModel.savePreferences()
                                    path.append(.setupKitchen)
                                } catch {
                                    errorMessage = ErrorPresenter.present(.sync01).message
                                }
                            }
                        },
                    )
                case .setupKitchen:
                    SetupKitchenView(
                        viewModel: viewModel,
                        onComplete: {
                            Task {
                                do {
                                    try viewModel.saveKitchen()
                                    try viewModel.completeOnboarding()
                                    onFinished()
                                } catch {
                                    errorMessage = ErrorPresenter.present(.sync01).message
                                }
                            }
                        },
                    )
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } },
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}
