// TutorialFlowHost
//
// Host for a single full-screen tutorial flow. Owns the lifecycle
// scaffolding that was previously copy-pasted across 8 `*Tutorial.swift`
// files (SCA-28 W4):
//
//   • `tutorial_started` is fired exactly once per replay cycle via
//     `TutorialManager.markStarted` (in-memory dedup that survives
//     view re-mount, fixing SCA-28 C4 — host churn would otherwise
//     reset a `@State` latch and double-fire the event).
//   • `tutorial_step_advanced` fires for each intra-tour advance,
//     never on the terminal "complete" tap.
//   • Resolution (`Done` / `Skip`) is gated by an `isAdvancing` latch
//     that defends against double-tap; calls
//     `manager.markCompleted(key)`, fires the matching terminal
//     event, logs, and dismisses.
//
// Each per-feature tutorial reduces to: a `Step` enum + a step-content
// `@ViewBuilder` switch + interactive miniature subviews. The
// lifecycle invariant ("exactly one of {completed, skipped} per
// started") becomes structural rather than enforced by copy-paste
// discipline.

import OSLog
import SwiftUI

struct TutorialFlowHost<Step: TutorialStep, Content: View>: View {
    let key: TutorialKey
    let initialStep: Step
    @ViewBuilder let content: (
        _ step: Step,
        _ advance: @escaping () -> Void,
        _ skip: @escaping () -> Void
    ) -> Content

    private let manager: TutorialManager
    private let posthog: PostHogClient

    @Environment(\.dismiss) private var dismiss
    @State private var isAdvancing = false

    init(
        key: TutorialKey,
        initialStep: Step,
        manager: TutorialManager = .shared,
        posthog: PostHogClient = .shared,
        @ViewBuilder content: @escaping (
            _ step: Step,
            _ advance: @escaping () -> Void,
            _ skip: @escaping () -> Void
        ) -> Content,
    ) {
        self.key = key
        self.initialStep = initialStep
        self.manager = manager
        self.posthog = posthog
        self.content = content
    }

    var body: some View {
        TutorialFlowContainer(
            initialStep: initialStep,
            onComplete: { resolve(skipped: false) },
            onSkip: { resolve(skipped: true) },
            onStepAdvance: { from, to in
                posthog.captureTutorialStepAdvanced(
                    key: key,
                    fromStep: from.telemetryID,
                    toStep: to.telemetryID,
                )
            },
            content: content,
        )
        .onAppear {
            // markStarted returns true ONLY on the first call per key
            // for this app session — re-mount of the host view (tab
            // swap, scene reset) won't re-fire the event because the
            // dedup lives on the manager, not view @State. Cleared on
            // markCompleted / reset / resetAll so replay re-arms.
            // SCA-28 C4.
            if manager.markStarted(key) {
                posthog.captureTutorialStarted(key: key)
            }
        }
    }

    @MainActor
    private func resolve(skipped: Bool) {
        // Re-entrancy guard — defends against rapid double-tap on
        // Done/Skip producing two terminal events. Not cleared
        // because resolve always dismisses; the cover content is torn
        // down + rebuilt on the next presentation cycle, so a fresh
        // `isAdvancing = false` lands automatically.
        guard !isAdvancing else { return }
        isAdvancing = true
        manager.markCompleted(key)
        if skipped {
            posthog.captureTutorialSkipped(key: key)
        } else {
            posthog.captureTutorialCompleted(key: key)
        }
        Logger.ui.info(
            "tutorial_resolved key=\(key.rawValue, privacy: .public) skipped=\(skipped, privacy: .public)",
        )
        dismiss()
    }
}

// MARK: - PostHog tutorial-event helpers (SCA-28 S1)
//
// Centralizes the per-tutorial property-bag construction so the four
// lifecycle events are the same shape across every flow. Adding a
// future property (e.g. `step_count` on tutorial_started) is now a
// one-line edit instead of a nine-file refactor.

extension PostHogClient {
    func captureTutorialStarted(key: TutorialKey) {
        capture(.tutorialStarted, properties: [
            "tutorial_id": key.telemetryID,
        ])
    }

    func captureTutorialStepAdvanced(
        key: TutorialKey,
        fromStep: String,
        toStep: String,
    ) {
        capture(.tutorialStepAdvanced, properties: [
            "tutorial_id": key.telemetryID,
            "from_step": fromStep,
            "to_step": toStep,
        ])
    }

    func captureTutorialCompleted(key: TutorialKey) {
        capture(.tutorialCompleted, properties: [
            "tutorial_id": key.telemetryID,
        ])
    }

    func captureTutorialSkipped(key: TutorialKey) {
        capture(.tutorialSkipped, properties: [
            "tutorial_id": key.telemetryID,
        ])
    }
}
