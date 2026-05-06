// Spacing.swift
//
// Stir spacing tokens — mirrors Specs/Design-System.md §5.1 + §5.2.
// Base unit 4pt; every inter-element spacing is a multiple of 4.
//
// Usage: `CGFloat.Stir.space4`, `CGFloat.Stir.screenMargin`.
// Prefer the named semantic aliases (`.screenMargin`) over raw tokens
// when the purpose is obvious; use `.space4` etc. for ad-hoc layouts.

import CoreGraphics

extension CGFloat {
    enum Stir {}
}

extension CGFloat.Stir {
    // MARK: - Base scale (multiples of 4pt)

    /// 4pt — icon-to-label gap inside a button.
    static let space1: CGFloat = 4
    /// 8pt — chip internal padding, tight stack.
    static let space2: CGFloat = 8
    /// 12pt — default between inline elements.
    static let space3: CGFloat = 12
    /// 16pt — screen horizontal margin, default section padding.
    static let space4: CGFloat = 16
    /// 24pt — block separation.
    static let space5: CGFloat = 24
    /// 32pt — major section break.
    static let space6: CGFloat = 32
    /// 48pt — page-level section.
    static let space7: CGFloat = 48

    // MARK: - Half-step scale (even-pt micro-adjusts)
    //
    // Mockup 02 + 03 + 04 + 05 lean on ~35 `.spaceN ± M` arithmetic
    // call sites for bespoke micro-spacing (6, 10, 14, 40, 36, 18 pt).
    // Named tokens collapse the arithmetic and let grep find all
    // consumers without hunting for inline math. Review finding W-C
    // W16 (CR2). Add more sub-tiers only when 3+ new arithmetic sites
    // want the same number — otherwise inline `+ 2` is clearer than
    // opaque "space2Plus".

    /// 6pt — halfway between space1 (4) and space2 (8). `.space1 + 2`.
    static let space1Half: CGFloat = 6
    /// 10pt — halfway between space2 (8) and space3 (12). `.space2 + 2`.
    static let space2Half: CGFloat = 10
    /// 14pt — halfway between space3 (12) and space4 (16). `.space3 + 2`.
    static let space3Half: CGFloat = 14
    /// 18pt — halfway between space4 (16) and space5 (24). Uncommon
    /// but landed in the mockup 05 action-stack pattern.
    static let space4Half: CGFloat = 18
    /// 40pt — between space6 (32) and space7 (48). Hero screens
    /// (Welcome, OnboardingCompletion).
    static let space6Hero: CGFloat = 40

    // MARK: - Semantic aliases

    /// Standard screen horizontal margin — 16pt.
    static let screenMargin: CGFloat = 16
    /// Hero screen horizontal margin (Welcome, Paywall feature modal) — 20pt.
    /// Not a scale multiple; deliberate 20pt for generous breathing room.
    static let screenMarginHero: CGFloat = 20

    /// Default vertical padding on interactive 48pt-tall targets.
    static let controlVerticalPadding: CGFloat = 14
    /// Default vertical padding on secondary (bordered) controls.
    static let controlVerticalPaddingSecondary: CGFloat = 12

    // MARK: - Tutorial layout dimensions

    /// 320pt — max width for the interactive miniatures inside the
    /// `*Tutorial` step content slot. Mirrors the body-copy clamp on
    /// `TutorialStepView.copyBlock` (line-length cap on iPhone widths,
    /// keeps the miniature visually contained on iPad). Promoted to a
    /// token from a dozen-plus `frame(maxWidth: 320)` literals across
    /// the SCA-19 tutorial files. SCA-28 S7.
    static let tutorialMiniatureMaxWidth: CGFloat = 320
}
