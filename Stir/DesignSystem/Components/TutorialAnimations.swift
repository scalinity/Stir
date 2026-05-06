// TutorialAnimations
//
// Reusable animation modifiers for tutorial step content. Lives in DS
// because the same primitives are likely to recur across `*Tutorial`
// step views and any future onboarding-adjacent surfaces (paywall hero
// reveals, win-back upsells).
//
// Two primitives:
//
//   • `.staggeredReveal(index:isVisible:)` — staggered list-item
//     entrance. `index` controls per-item delay; `isVisible` is the
//     local appear-trigger driven by `.onAppear` in the host step.
//
//   • `.tutorialPulsing()` — repeating scale (1.0 ↔ 1.06) for emphasis
//     elements (CTA glyph, fake spotlight ring). Honours
//     `accessibilityReduceMotion` — renders static when the user
//     opted out of motion.
//
// Tuned for full-screen tutorial step content — gentle enough to live
// next to a primary CTA, present enough to draw the eye to a focal
// element on a single tutorial step.

import SwiftUI

// MARK: - Staggered reveal

private struct StaggeredRevealModifier: ViewModifier {
    let index: Int
    let isVisible: Bool
    let baseDelay: Double
    let perItemDelay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 12)
            .animation(
                reduceMotion
                    ? nil
                    : .easeOut(duration: 0.32)
                        .delay(baseDelay + Double(index) * perItemDelay),
                value: isVisible,
            )
    }
}

extension View {
    /// Stagger a row's appearance after the host view appears. `index`
    /// picks the slot in the cascade (0 = first), `isVisible` is the
    /// host's @State trigger that flips true on appear.
    ///
    /// Honours reduce-motion by rendering immediately at full opacity
    /// (the modifier is a no-op in that case rather than a snap-cut).
    func staggeredReveal(
        index: Int,
        isVisible: Bool,
        baseDelay: Double = 0.18,
        perItemDelay: Double = 0.08,
    ) -> some View {
        modifier(
            StaggeredRevealModifier(
                index: index,
                isVisible: isVisible,
                baseDelay: baseDelay,
                perItemDelay: perItemDelay,
            ),
        )
    }
}

// MARK: - Tutorial pulse

private struct TutorialPulsingModifier: ViewModifier {
    let scale: CGFloat
    let duration: Double

    @State private var isPulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1.0 : (isPulsing ? scale : 1.0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(
                    .easeInOut(duration: duration).repeatForever(autoreverses: true),
                ) {
                    isPulsing = true
                }
            }
    }
}

extension View {
    /// Repeating scale animation for emphasis elements. Default scale
    /// 1.06 / duration 0.9s autoreverses — gentle enough not to be
    /// distracting next to a primary CTA, present enough to draw the
    /// eye to a single focal element on a tutorial step.
    func tutorialPulsing(
        scale: CGFloat = 1.06,
        duration: Double = 0.9,
    ) -> some View {
        modifier(TutorialPulsingModifier(scale: scale, duration: duration))
    }
}
