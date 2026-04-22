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
}
