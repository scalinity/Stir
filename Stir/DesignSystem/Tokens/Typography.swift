// Typography.swift
//
// Stir typography tokens — mirrors Specs/Design-System.md §4.
//
// Two faces: New York (display) and SF Pro (body/label/mono).
// Tracking, exact point size, and line height are baked into every token.
// Dynamic Type is honored via `@ScaledMetric` anchored to a matching
// `Font.TextStyle`, so each token scales from its spec baseline
// (34/28/22/…/44pt) up or down with the user's type-size setting,
// WITHOUT drifting to Apple's TextStyle default sizes (which would
// shrink `monoLg` from 44 → 34pt and offset 6 others by ±1–2pt).
//
// Public API: `.stirFont(.displayLg)` — one view modifier, applies
// font + tracking + line spacing + Dynamic Type + optional uppercase.
// Never use `.font(.title2.bold())` or raw `.system(size:)` calls in
// feature code. Lint: new hardcoded font modifiers in `Stir/Features/`
// get flagged in review.

import SwiftUI

// MARK: - StirTypeStyle
//
// Each token carries the spec baseline (`size`, `lineHeight`) and the
// Dynamic Type anchor (`relativeTo`). `StirFontModifier` uses both to
// produce a `Font.system(size:weight:design:)` whose size scales via
// `@ScaledMetric`. This is the only way to get exact-baseline + Dynamic
// Type scaling in SwiftUI without shipping custom fonts.

struct StirTypeStyle {
    /// Default point size at standard Dynamic Type. Scales with `relativeTo`.
    let size: CGFloat
    /// Default line height at standard Dynamic Type. Scales with `relativeTo`.
    /// `lineSpacing` = `lineHeight - size` (scaled).
    let lineHeight: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    /// Letter-spacing in points. Not scaled with Dynamic Type — em-derived
    /// tracking stays proportional through `.tracking()` automatically.
    let tracking: CGFloat
    /// Dynamic Type anchor. Drives both size and lineHeight scaling.
    let relativeTo: Font.TextStyle
    let uppercase: Bool

    // MARK: Display (New York, Semibold)

    /// 34pt / 40 LH / tracking -0.02em. Welcome + paywall hero.
    static let displayXl = StirTypeStyle(
        size: 34, lineHeight: 40,
        weight: .semibold, design: .serif,
        tracking: -0.68,              // 34 × -0.02em
        relativeTo: .largeTitle,
        uppercase: false,
    )
    /// 28pt / 34 LH / -0.02em. Screen titles (Tonight, Saved, Settings).
    static let displayLg = StirTypeStyle(
        size: 28, lineHeight: 34,
        weight: .semibold, design: .serif,
        tracking: -0.56,              // 28 × -0.02em
        relativeTo: .title,
        uppercase: false,
    )
    /// 22pt / 28 LH / -0.015em. Section headers, dish titles.
    static let displayMd = StirTypeStyle(
        size: 22, lineHeight: 28,
        weight: .semibold, design: .serif,
        tracking: -0.33,              // 22 × -0.015em
        relativeTo: .title2,
        uppercase: false,
    )
    /// 18pt / 24 LH / -0.01em. In-card subheadings, pricing labels.
    static let displaySm = StirTypeStyle(
        size: 18, lineHeight: 24,
        weight: .semibold, design: .serif,
        tracking: -0.18,              // 18 × -0.01em
        relativeTo: .title3,
        uppercase: false,
    )

    // MARK: Body (SF Pro, Regular)

    /// 17pt / 24 LH. Cook Mode step instruction only.
    static let bodyLg = StirTypeStyle(
        size: 17, lineHeight: 24,
        weight: .regular, design: .default,
        tracking: 0,
        relativeTo: .body,
        uppercase: false,
    )
    /// 15pt / 22 LH. Default body.
    static let bodyMd = StirTypeStyle(
        size: 15, lineHeight: 22,
        weight: .regular, design: .default,
        tracking: 0,
        relativeTo: .callout,
        uppercase: false,
    )
    /// 13pt / 18 LH. Captions, metadata.
    static let bodySm = StirTypeStyle(
        size: 13, lineHeight: 18,
        weight: .regular, design: .default,
        tracking: 0,
        relativeTo: .footnote,
        uppercase: false,
    )

    // MARK: Label (SF Pro, Medium)

    /// 15pt / 20 LH. Button labels, chip text.
    static let labelLg = StirTypeStyle(
        size: 15, lineHeight: 20,
        weight: .medium, design: .default,
        tracking: 0,
        relativeTo: .callout,
        uppercase: false,
    )
    /// 13pt / 18 LH. Small button labels, tab bar.
    static let labelMd = StirTypeStyle(
        size: 13, lineHeight: 18,
        weight: .medium, design: .default,
        tracking: 0,
        relativeTo: .footnote,
        uppercase: false,
    )

    // MARK: Eyebrow (SF Pro, Bold, UPPERCASE, tracked)

    /// 11pt / 14 LH / +0.14em. UPPERCASE section eyebrows ("PRO FEATURE").
    /// `StirFontModifier` applies `.textCase(.uppercase)` automatically.
    static let labelEyebrow = StirTypeStyle(
        size: 11, lineHeight: 14,
        weight: .bold, design: .default,
        tracking: 1.54,               // 11 × 0.14em
        relativeTo: .caption,
        uppercase: true,
    )
    /// 10pt / 13 LH / +0.12em. UPPERCASE tier labels ("MONTHLY", "ANNUAL").
    static let labelMicroEyebrow = StirTypeStyle(
        size: 10, lineHeight: 13,
        weight: .bold, design: .default,
        tracking: 1.20,               // 10 × 0.12em
        relativeTo: .caption2,
        uppercase: true,
    )

    // MARK: Monospace (SF Mono, tabular digits)

    /// 15pt / 22 LH. Timer countdowns, measurements in recipe.
    static let monoMd = StirTypeStyle(
        size: 15, lineHeight: 22,
        weight: .regular, design: .monospaced,
        tracking: 0,
        relativeTo: .callout,
        uppercase: false,
    )
    /// 44pt / 48 LH. Cook Mode hero timer. Pair with `.monospacedDigit()`
    /// at the call site for tabular num rendering. Baseline preserved at
    /// 44pt exactly — `@ScaledMetric` scales from there.
    static let monoLg = StirTypeStyle(
        size: 44, lineHeight: 48,
        weight: .medium, design: .monospaced,
        tracking: 0,
        relativeTo: .largeTitle,
        uppercase: false,
    )
    /// 13pt / 18 LH. Voice-command quotes ("say *next*").
    static let monoQuote = StirTypeStyle(
        size: 13, lineHeight: 18,
        weight: .medium, design: .monospaced,
        tracking: 0,
        relativeTo: .footnote,
        uppercase: false,
    )
}

// MARK: - View modifier

extension View {
    /// Apply a Stir typography token — exact-baseline font + tracking +
    /// line spacing + Dynamic Type scaling + optional uppercase — in one
    /// chain. The only public typography API; feature code never builds
    /// `Font.system(...)` directly.
    func stirFont(_ style: StirTypeStyle) -> some View {
        modifier(StirFontModifier(style: style))
    }
}

private struct StirFontModifier: ViewModifier {
    let style: StirTypeStyle
    @ScaledMetric private var scaledSize: CGFloat
    @ScaledMetric private var scaledLineHeight: CGFloat

    init(style: StirTypeStyle) {
        self.style = style
        self._scaledSize = ScaledMetric(
            wrappedValue: style.size,
            relativeTo: style.relativeTo,
        )
        self._scaledLineHeight = ScaledMetric(
            wrappedValue: style.lineHeight,
            relativeTo: style.relativeTo,
        )
    }

    func body(content: Content) -> some View {
        let font = Font.system(
            size: scaledSize,
            weight: style.weight,
            design: style.design,
        )
        let scaledLineSpacing = max(0, scaledLineHeight - scaledSize)
        let styled = content
            .font(font)
            .tracking(style.tracking)
            .lineSpacing(scaledLineSpacing)
        if style.uppercase {
            styled.textCase(.uppercase)
        } else {
            styled
        }
    }
}
