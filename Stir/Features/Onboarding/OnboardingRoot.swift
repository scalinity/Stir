// OnboardingRoot
//
// NavigationStack + routing wrapper. Instantiated by RootCoordinator when
// HouseholdProfile.onboardingCompleted == false (commit 9).
//
// Mockup 02 adds the `.completionTransition` surface between Setup 2
// and `onFinished()`. Setup 2's handler now pushes the transition
// route instead of calling onFinished directly; OnboardingCompletion-
// View saves `completeOnboarding()` on appear (so kill-during-dwell
// still counts as completed — decision b), dwells ~1.5s, then fires
// onFinished to flip coordinator phase to `.ready`.

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
                        onBack: { path.removeLast() },
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
                        // Skip wiring lands in commit 3 — no-op here
                        // preserves the affordance visually without
                        // changing behavior mid-phase-3.
                        onSkip: {},
                    )
                case .setupKitchen:
                    SetupKitchenView(
                        viewModel: viewModel,
                        onBack: { path.removeLast() },
                        onComplete: {
                            Task {
                                do {
                                    try viewModel.saveKitchen()
                                    path.append(.completionTransition)
                                } catch {
                                    errorMessage = ErrorPresenter.present(.sync01).message
                                }
                            }
                        },
                        onSkip: {},
                    )
                case .completionTransition:
                    OnboardingCompletionView(
                        viewModel: viewModel,
                        onFinished: onFinished,
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
