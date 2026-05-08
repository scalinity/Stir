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
//
// Double-tap defense (review finding C4):
//   - `isAdvancing` gates every Continue/Skip/See-a-sample handler so
//     rapid taps can't enqueue duplicate save+push tasks. `defer {
//     isAdvancing = false }` releases the latch once the Task settles.
//   - `OnboardingViewModel.fireOnboardingCompletedEvent()` is also
//     idempotent at the VM level — belt-and-suspenders against
//     NavigationStack's `.task` re-running on OnboardingCompletionView
//     re-appearance.

import OSLog
import SwiftUI

struct OnboardingRoot: View {
    @Bindable var viewModel: OnboardingViewModel
    let onFinished: () -> Void

    @State private var path: [OnboardingRoute] = []
    @State private var errorMessage: String?
    /// In-flight flag for the Welcome + Setup handlers below. Set at
    /// Task entry, cleared via `defer` on Task exit. Prevents the
    /// double-tap class of route-push + telemetry-double-fire bugs
    /// (review finding C4).
    @State private var isAdvancing = false

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeView(
                onTryIt: {
                    guard !isAdvancing else { return }
                    path.append(.setupPreferences)
                },
                onSeeSample: {
                    guard !isAdvancing else { return }
                    // SCA-67: route into the showcase, NOT directly
                    // into the bypass-to-Tonight. The showcase's "Try
                    // with your real kitchen" CTA reuses the bypass
                    // logic via OnboardingRoute.sampleShowcase →
                    // SampleShowcaseView's onContinueOnboarding.
                    path.append(.sampleShowcase)
                },
            )
            .navigationDestination(for: OnboardingRoute.self) { route in
                switch route {
                case .setupPreferences:
                    SetupPreferencesView(
                        viewModel: viewModel,
                        onBack: { path.removeLast() },
                        onContinue: {
                            guard !isAdvancing else { return }
                            isAdvancing = true
                            Task {
                                defer { isAdvancing = false }
                                do {
                                    try viewModel.savePreferences()
                                    path.append(.setupKitchen)
                                } catch {
                                    Logger.ui.error(
                                        "onboarding_setup1_continue_failed: \(error.localizedDescription, privacy: .public)",
                                    )
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
                            guard !isAdvancing else { return }
                            isAdvancing = true
                            Task {
                                defer { isAdvancing = false }
                                do {
                                    try viewModel.savePreferences()
                                    viewModel.recordSkip(over: "setup_kitchen")
                                    path.append(.completionTransition)
                                } catch {
                                    Logger.ui.error(
                                        "onboarding_setup1_skip_failed: \(error.localizedDescription, privacy: .public)",
                                    )
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
                            guard !isAdvancing else { return }
                            isAdvancing = true
                            Task {
                                defer { isAdvancing = false }
                                do {
                                    try viewModel.saveKitchen()
                                    path.append(.completionTransition)
                                } catch {
                                    Logger.ui.error(
                                        "onboarding_setup2_complete_failed: \(error.localizedDescription, privacy: .public)",
                                    )
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
                            guard !isAdvancing else { return }
                            isAdvancing = true
                            Task {
                                defer { isAdvancing = false }
                                do {
                                    try viewModel.saveKitchen()
                                    path.append(.completionTransition)
                                } catch {
                                    Logger.ui.error(
                                        "onboarding_setup2_skip_failed: \(error.localizedDescription, privacy: .public)",
                                    )
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
                case .sampleShowcase:
                    SampleShowcaseView(
                        onPrimaryAction: {
                            guard !isAdvancing else { return }
                            isAdvancing = true
                            // Reuse the original "See a sample" bypass
                            // logic — persist zero-selection defaults,
                            // record skips, complete onboarding inline
                            // (no completion-transition for the sample
                            // path), land on Tonight Home.
                            Task {
                                defer { isAdvancing = false }
                                do {
                                    try viewModel.savePreferences()
                                    try viewModel.saveKitchen()
                                    viewModel.recordSkip(over: "setup_preferences")
                                    viewModel.recordSkip(over: "setup_kitchen")
                                    try viewModel.completeOnboarding()
                                    viewModel.fireOnboardingCompletedEvent()
                                    onFinished()
                                } catch {
                                    Logger.ui.error(
                                        "onboarding_sample_continue_failed: \(error.localizedDescription, privacy: .public)",
                                    )
                                    errorMessage = ErrorPresenter.present(.sync01).message
                                }
                            }
                        },
                        onBack: {
                            path.removeLast()
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
