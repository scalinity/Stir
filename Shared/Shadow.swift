// Shadow.swift
//
// Stir shadow tokens — mirrors Specs/Design-System.md §5.5 +
// stir-app-design/project/DesignMockups/EXTRACTED_TOKENS.md §6.2.
//
// Light mode default: NO drop shadows. Elevation via 1pt hairline borders
// + fill step-up (ink.100 on paper.50 for cards; paper.100 on paper.50 for
// sheets). The shadows defined below are the ONLY sanctioned drop-shadow
// uses; ad-hoc `.shadow(color:radius:x:y:)` calls fight the warm paper
// palette and read as grimy.
//
// Usage:
//   .stirShadow(.sheetEdge)
//   .stirShadow(.emberGlow)
//   .stirShadow(StirShadow.cookStepCard(for: colorScheme))   // dark-mode-only
//
// If you find yourself reaching for `.shadow(color:radius:x:y:)` directly,
// check this file first. New shadow patterns require adding a named token
// here AND updating Design-System.md §5.5 in the same PR.
//
// Token location rationale: lives in /Shared/ per ADR 0016 so the same
// shadow vocabulary is available to widget + share-extension targets.
// Widget Live Activity currently uses `sheetEdge`-equivalent patterns.

import SwiftUI

struct StirShadow {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    // MARK: - Bottom-sheet top-edge separator

    /// Top-edge shadow on bottom sheets — separates the sheet from the
    /// content it overlays. Used on Substitution Sheet, Cook Mode step
    /// card bottom sheet, paywall soft-sheet variant, grocery export
    /// sheet. `color: .black.opacity(0.08), radius: 24, y: -8`.
    static let sheetEdge = StirShadow(
        color: Color.black.opacity(0.08),
        radius: 24,
        x: 0,
        y: -8,
    )

    // MARK: - Centered modal elevation

    /// Centered modal — the deepest elevation in the system. Used for
    /// the paywall voice-upsell feature modal and the substitution
    /// result card overlay. `color: .black.opacity(0.25), radius: 30, y: 15`.
    static let modal = StirShadow(
        color: Color.black.opacity(0.25),
        radius: 30,
        x: 0,
        y: 15,
    )

    // MARK: - Cook Mode step card (DARK MODE ONLY — Spec §5.5 exception)

    /// Cook Mode step card — ONLY rendered on dark mode to separate the
    /// card from a dim kitchen background. Light mode renders the same
    /// card with a 1pt hairline border and no shadow. Use via the
    /// color-scheme-aware helper `StirShadow.cookStepCard(for:)`.
    /// `color: .black.opacity(0.35), radius: 12, y: 4`.
    static let cookStepCardDark = StirShadow(
        color: Color.black.opacity(0.35),
        radius: 12,
        x: 0,
        y: 4,
    )

    /// Returns the Cook Mode step-card shadow when the current color
    /// scheme is dark; returns `nil` on light mode per Spec §5.5. Pair
    /// with `.stirShadow(_:)` which no-ops on `nil`.
    static func cookStepCard(for colorScheme: ColorScheme) -> StirShadow? {
        colorScheme == .dark ? .cookStepCardDark : nil
    }

    // MARK: - Ember glow (Cook Mode primary action)

    /// Colored glow on the Cook Mode primary action (mic button active
    /// state, Next-Step CTA). The color uses `ember.600` at 27% alpha
    /// so light/dark resolution is automatic via the underlying adaptive
    /// color. `color: Color.Stir.ember600.opacity(0.27), radius: 10, y: 6`.
    static let emberGlow = StirShadow(
        color: Color.Stir.ember600.opacity(0.27),
        radius: 10,
        x: 0,
        y: 6,
    )

    // MARK: - Soft-press 3D button effect

    /// Skeuomorphic 2pt y-drop under interactive cards and primary CTAs —
    /// gives the button a tactile "pressed" feel without animation.
    /// Uses the adaptive `Color.Stir.pressShadow` (light `#E8E1D4`,
    /// dark `#2A2520`) so the drop reads as a soft companion, not a
    /// black shadow. Radius 0 — this is a flat offset, not a blur.
    static let softPress = StirShadow(
        color: Color.Stir.pressShadow,
        radius: 0,
        x: 0,
        y: 2,
    )
}

// MARK: - View modifier

extension View {
    /// Apply a Stir shadow token. Prefer this over
    /// `.shadow(color:radius:x:y:)` — ad-hoc shadows fight the paper
    /// palette in light mode. `nil` is a no-op, which lets callers pass
    /// the result of `StirShadow.cookStepCard(for:)` directly.
    @ViewBuilder
    func stirShadow(_ shadow: StirShadow?) -> some View {
        if let shadow {
            self.shadow(
                color: shadow.color,
                radius: shadow.radius,
                x: shadow.x,
                y: shadow.y,
            )
        } else {
            self
        }
    }
}
