// TutorialFlowContainer
//
// Page-dot progress indicator over multi-step tutorial content. Page
// dots not a progress bar — chosen for "tour" affordance vs "task in
// progress" affordance, matching the Welcome screen's restrained-brand
// grammar.
//
// Conformers' `RawValue == Int` MUST start at 0 and be contiguous —
// `progressFraction`, the dot indicator, and the accessibility label
// all assume that.

import SwiftUI

/// Step enum contract for `TutorialFlowContainer` / `TutorialFlowHost`.
///
/// `RawValue == Int` so the container can use `0..<count` and
/// `Step(rawValue: current + 1)` for the dot indicator and advance
/// lookup; `CaseIterable` so the dot indicator has a count.
///
/// `telemetryID` is required (SCA-28 W4) so a generic host can pull the
/// snake_case PostHog string off any step without an ad-hoc protocol-
/// witness extension dance. Keep IDs lowercase + underscored;
/// `TutorialFlowContainerTests.test_telemetryIDs_areSnakeCase` enforces.
protocol TutorialStep: RawRepresentable, CaseIterable, Hashable where RawValue == Int {
    /// PostHog `from_step` / `to_step` property — snake_case lowercase.
    var telemetryID: String { get }
}

extension TutorialStep {
    /// 1-indexed completion ratio — current step is rendered as
    /// "completed". Caller-facing semantics: "you've reached step
    /// `progressFraction * count`". Today only used for the
    /// accessibility label; documented contract for future
    /// `ProgressView` consumers.
    var progressFraction: Double {
        Double(rawValue + 1) / Double(Self.allCases.count)
    }
}

struct TutorialFlowContainer<Step: TutorialStep, Content: View>: View {
    let initialStep: Step
    let onComplete: () -> Void
    let onSkip: () -> Void
    /// Fires on every intra-tour advance. Final-step "complete" tap
    /// does NOT fire this — the `tutorial_completed` event is the
    /// terminal signal. (review DB1 S2, DB3 W5)
    let onStepAdvance: ((_ from: Step, _ to: Step) -> Void)?
    @ViewBuilder let content: (
        _ step: Step,
        _ advance: @escaping () -> Void,
        _ skip: @escaping () -> Void
    ) -> Content

    @State private var currentStep: Step
    @State private var isTransitioning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Step count — hoisted off `Step.allCases.count` so it isn't
    /// recomputed on every body re-eval. `CaseIterable.allCases`
    /// allocates a fresh Array each call on synthesized enums; the
    /// dot indicator + animation duration both read this. SCA-28 W13.
    private let stepCount: Int = Step.allCases.count

    init(
        initialStep: Step,
        onComplete: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        onStepAdvance: ((_ from: Step, _ to: Step) -> Void)? = nil,
        @ViewBuilder content: @escaping (
            _ step: Step,
            _ advance: @escaping () -> Void,
            _ skip: @escaping () -> Void
        ) -> Content,
    ) {
        self.initialStep = initialStep
        _currentStep = State(initialValue: initialStep)
        self.onComplete = onComplete
        self.onSkip = onSkip
        self.onStepAdvance = onStepAdvance
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            progressDots
                .padding(.top, CGFloat.Stir.space5)
                .padding(.horizontal, CGFloat.Stir.screenMargin)

            content(currentStep, advance, skip)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(currentStep)
                .transition(stepTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Stir.paper50.ignoresSafeArea())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: currentStep)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Progress dots

    private var progressDots: some View {
        // Iterate the rawValue range — protocol contracts contiguity
        // starting at 0, so `0..<count` and `currentStep.rawValue`
        // align without materializing an Array. Single .animation
        // modifier on the parent already covers dot transitions; no
        // per-dot .animation here.
        HStack(spacing: CGFloat.Stir.space2) {
            ForEach(0..<stepCount, id: \.self) { idx in
                Capsule()
                    // 20pt active / 8pt inactive — page-dot indicator
                    // sized matching the Welcome screen's bowl-rim
                    // dots. Distinct from any token because no other
                    // surface uses dot indicators.
                    .fill(idx == currentStep.rawValue ? Color.Stir.ember600 : Color.Stir.ink100)
                    .frame(width: idx == currentStep.rawValue ? 20 : 8, height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(currentStep.rawValue + 1) of \(stepCount)")
    }

    // MARK: - Step transitions

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity),
        )
    }

    // MARK: - Step machinery

    private func advance() {
        // Block re-entry while a step transition is in flight so a
        // tap-spam doesn't fire `tutorial_step_advanced` N times in
        // <250ms. The 0.25s window matches the parent `.animation`
        // duration; clears via Task.sleep so an ill-timed cover
        // dismiss doesn't strand the flag. SCA-28 W14.
        guard !isTransitioning else { return }
        if let next = Step(rawValue: currentStep.rawValue + 1) {
            isTransitioning = true
            let from = currentStep
            currentStep = next
            onStepAdvance?(from, next)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                isTransitioning = false
            }
        } else {
            // Final-step "complete" tap: routes to onComplete (which
            // fires `tutorial_completed`) and not onStepAdvance — the
            // documented carve-out (SCA-28 W12 pinned by test). No
            // re-entry guard here because onComplete dismisses.
            onComplete()
        }
    }

    private func skip() {
        onSkip()
    }
}
