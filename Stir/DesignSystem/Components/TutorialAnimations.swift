// TutorialAnimations
//
// Reusable animation modifiers for tutorial step content. Lives in DS
// because the same primitives are likely to recur across `*Tutorial`
// step views and any future onboarding-adjacent surfaces (paywall hero
// reveals, win-back upsells).
//
// Three primitives:
//
//   • `.staggeredReveal(index:isVisible:)` — staggered list-item
//     entrance. `index` controls per-item delay; `isVisible` is the
//     local appear-trigger driven by `.onAppear` in the host step.
//
//   • `.tutorialFadeIn(isVisible:)` — single-element fade + offset
//     entrance (the `index: 0` case of staggered reveal). Lifted into
//     a named modifier so the open-coded `opacity + offset + animation`
//     idiom across the *Tutorial miniatures collapses to one line and
//     picks up reduce-motion compliance for free. SCA-28 W15.
//
//   • `.tutorialPulsing()` — repeating scale (1.0 ↔ 1.06) for emphasis
//     elements (CTA glyph, fake spotlight ring). Honours
//     `accessibilityReduceMotion` — renders static when the user
//     opted out of motion. Cancels the implicit animation on
//     `.onDisappear` so the driver doesn't outlive the view, which is
//     a documented iOS-17+ pitfall when `.repeatForever` lacks an
//     explicit terminator. SCA-28 W1.
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
        if reduceMotion {
            // Reduce-motion path: render the content unmodified rather
            // than snap-cutting from invisible→visible. Earlier
            // implementation kept the `opacity(isVisible ? 1 : 0)` +
            // `offset` bindings under reduce-motion, which produced an
            // instantaneous snap rather than a true no-op (SCA-28 S3).
            content
        } else {
            content
                .opacity(isVisible ? 1 : 0)
                .offset(y: isVisible ? 0 : 12)
                .animation(
                    .easeOut(duration: 0.32)
                        .delay(baseDelay + Double(index) * perItemDelay),
                    value: isVisible,
                )
        }
    }
}

extension View {
    /// Stagger a row's appearance after the host view appears. `index`
    /// picks the slot in the cascade (0 = first), `isVisible` is the
    /// host's @State trigger that flips true on appear.
    ///
    /// Reduce-motion is a true no-op — the modifier returns content
    /// unchanged, so items render in their final position immediately
    /// rather than snap-cutting from invisible to visible.
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

    /// Single-element fade + offset entrance. Convenience overload of
    /// `staggeredReveal(index: 0, isVisible:)` — lets the dozen-plus
    /// open-coded `opacity(visible ? 1 : 0) + offset + .animation`
    /// sites in the *Tutorial miniatures collapse to one modifier
    /// while picking up reduce-motion compliance.
    func tutorialFadeIn(isVisible: Bool, delay: Double = 0.18) -> some View {
        staggeredReveal(index: 0, isVisible: isVisible, baseDelay: delay)
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
            .onDisappear {
                // Stop the implicit animation deterministically on
                // disappear. SwiftUI's `repeatForever` has no built-in
                // stop affordance; without this cleanup the animation
                // driver outlives the view and accumulates across
                // present cycles (Settings replay × N) until process
                // exit. The disabled-animations transaction lets the
                // value commit without creating a brand-new animation
                // segment. SCA-28 W1.
                var txn = Transaction()
                txn.disablesAnimations = true
                withTransaction(txn) {
                    isPulsing = false
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
