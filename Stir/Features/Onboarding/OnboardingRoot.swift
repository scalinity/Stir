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
                    // Step-2 stub — sample path bypasses Setup 1/2
                    // entirely, so it records every subsequent step as
                    // skipped and fires `onboarding_completed` inline
                    // (no completion-transition for this path).
                    Task {
                        do {
                            viewModel.recordSkip(over: "setup_preferences")
                            viewModel.recordSkip(over: "setup_kitchen")
                            try viewModel.completeOnboarding()
                            viewModel.fireOnboardingCompletedEvent()
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
                        onSkip: {
                            // Skip from Setup 1 saves whatever the
                            // user has selected so far, records
                            // "setup_kitchen" as bypassed, and routes
                            // straight to the completion transition.
                            // The current step (Setup 1) counts as
                            // visited-and-partially-completed per
                            // decision (a).
                            Task {
                                do {
                                    try viewModel.savePreferences()
                                    viewModel.recordSkip(over: "setup_kitchen")
                                    path.append(.completionTransition)
                                } catch {
                                    errorMessage = ErrorPresenter.present(.sync01).message
                                }
                            }
                        },
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
                        onSkip: {
                            // Skip from Setup 2 saves kitchen state
                            // and routes to completion. No recordSkip
                            // — there are no steps AFTER Setup 2 to
                            // bypass; Setup 2 itself counts as
                            // partially-completed (decision a).
                            Task {
                                do {
                                    try viewModel.saveKitchen()
                                    path.append(.completionTransition)
                                } catch {
                                    errorMessage = ErrorPresenter.present(.sync01).message
                                }
                            }
                        },
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
