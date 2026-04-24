// Motion.swift
//
// Stir motion tokens — mirrors Specs/Design-System.md §7 +
// stir-app-design/project/DesignMockups/_shared/colors_and_type.css §Motion.
//
// Three durations. Two easings. One spring (voice mic activation only).
// Reduce Motion is honored: when the user has Accessibility → Motion →
// Reduce Motion enabled, animations degrade to instant. The
// `.stirAnimation(_:value:)` view modifier reads
// `@Environment(\.accessibilityReduceMotion)` and returns `nil` to
// SwiftUI's `.animation(_:value:)`, which disables the transition.
//
// Usage:
//   .stirAnimation(.Stir.standard, value: isActive)
//   .stirAnimation(.Stir.sheet,    value: isPresented)
//   withAnimation(.Stir.voiceMicActivation) { isRecording = true }
//
// If you find yourself reaching for `.animation(.easeOut(duration: 0.2))`
// or bare `withAnimation { }`, check this file first. Motion that doesn't
// respect Reduce Motion is an accessibility bug.
//
// Token location: `/Shared/` per ADR 0016. Animation namespace is
// `Animation.Stir.*` (matching `Color.Stir.*`, `Font.Stir.*`).

import SwiftUI

extension Animation {
    enum Stir {}
}

extension Animation.Stir {
    // MARK: - Named tokens

    /// Default motion — `.easeOut(duration: 0.2)`. Most state changes.
    /// Use for chip selection, toggle flips, card-in/out transitions,
    /// error-banner reveal.
    static let standard: Animation = .easeOut(duration: 0.20)

    /// Exit motion — `.easeIn(duration: 0.15)`. Dismissal, fade-out.
    /// Faster than `.standard` so dismissal doesn't feel sticky.
    /// Spec §7.2 explicit.
    static let exit: Animation = .easeIn(duration: 0.15)

    /// Sheet presentation — `.easeOut(duration: 0.3)`. The ceiling for
    /// sustained animation. Use only for full-sheet / bottom-sheet
    /// presentation; shorter animations (modals, overlays) should use
    /// `.standard`.
    static let sheet: Animation = .easeOut(duration: 0.30)

    /// Voice mic activation — the ONE spring-animated surface in the
    /// app. Concentric pulse ring on first mic tap only, 400ms spring
    /// from 0.9 → 1.0 scale. Spec §7.3 explicit: "No spring animations
    /// on functional UI. Springs are reserved for the voice mic
    /// activation glow — the one place a tiny bit of delight is earned."
    static let voiceMicActivation: Animation = .spring(
        response: 0.4,
        dampingFraction: 0.7,
    )
}

// MARK: - Raw duration tokens
//
// Exposed for call sites that need the TimeInterval directly (Timeline
// refresh cadences, debounce windows, etc). Prefer the `Animation.Stir.*`
// tokens for SwiftUI animations.
//
// Renamed from `TimeInterval.StirMotion` to `TimeInterval.Stir` to match
// the single-word namespace used by `Color.Stir`, `CGFloat.Stir`, and
// `Font.Stir`. Review finding S6 (CR2).

extension TimeInterval {
    enum Stir {}
}

extension TimeInterval.Stir {
    /// 0.15s — exit transitions.
    static let fast: TimeInterval = 0.15
    /// 0.20s — default state-change transitions.
    static let `default`: TimeInterval = 0.20
    /// 0.30s — sheet presentation ceiling.
    static let sheet: TimeInterval = 0.30
}

// MARK: - Reduce Motion–aware view modifier

private struct StirAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// Apply a Stir animation that respects the user's Reduce Motion
    /// setting. When Reduce Motion is enabled in Accessibility settings,
    /// the animation is dropped and the transition becomes instant
    /// (Spec §7.1: "All motion degrades to instant or cross-fade when
    /// the user has Reduce Motion enabled.").
    ///
    /// Reads `@Environment(\.accessibilityReduceMotion)` internally, so
    /// callers don't need to thread the accessibility flag manually.
    ///
    /// Prefer this over `.animation(_:value:)` at view layer — ad-hoc
    /// animation calls that skip the Reduce Motion check are an
    /// accessibility bug.
    func stirAnimation<Value: Equatable>(
        _ animation: Animation,
        value: Value,
    ) -> some View {
        modifier(StirAnimationModifier(animation: animation, value: value))
    }
}

// MARK: - Imperative withAnimation helper
//
// For button-handler / closure callsites where `.stirAnimation(_:value:)`
// doesn't fit. Takes the same `reduceMotion` flag — callers read it from
// the environment at their layer and pass it in.

/// Wraps `withAnimation(_:_:)` but respects Reduce Motion. When
/// `reduceMotion` is `true`, the closure runs without animation.
///
/// Usage at a call site:
///
///     @Environment(\.accessibilityReduceMotion) private var reduceMotion
///     ...
///     Button("Start") {
///         withStirAnimation(.Stir.voiceMicActivation, reduceMotion: reduceMotion) {
///             isRecording = true
///         }
///     }
@discardableResult
func withStirAnimation<Result>(
    _ animation: Animation,
    reduceMotion: Bool,
    _ body: () throws -> Result,
) rethrows -> Result {
    if reduceMotion {
        return try body()
    } else {
        return try withAnimation(animation, body)
    }
}
