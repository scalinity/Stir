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

protocol TutorialStep: RawRepresentable, CaseIterable, Hashable where RawValue == Int {}

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        let count = Step.allCases.count
        return HStack(spacing: CGFloat.Stir.space2) {
            ForEach(0..<count, id: \.self) { idx in
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
        .accessibilityLabel("Step \(currentStep.rawValue + 1) of \(count)")
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
        if let next = Step(rawValue: currentStep.rawValue + 1) {
            let from = currentStep
            currentStep = next
            onStepAdvance?(from, next)
        } else {
            onComplete()
        }
    }

    private func skip() {
        onSkip()
    }
}
