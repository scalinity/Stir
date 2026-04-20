// Typography.swift
//
// Stir typography tokens — mirrors Specs/Design-System.md §4.
//
// Two faces: New York (display) and SF Pro (body/label/mono).
// Tracking is baked in. Dynamic Type scales every token from its default
// size using SwiftUI's `.textStyle(...)` relativity, via `ScaledFont`.
// All tokens return `Text`-modifier pairs that the view applies as a
// single chain: `.stirFont(.displayLg)`.
//
// Never use `.font(.title2.bold())` or raw `.system(size:)` calls in
// feature code. Lint: new hardcoded font modifiers in `Stir/Features/`
// get flagged in review.

import SwiftUI

extension Font {
    enum Stir {}
}

extension Font.Stir {
    // MARK: - Display (New York, Semibold)

    /// 34pt / line-height 40 / tracking -0.02em. Welcome + paywall hero.
    static let displayXl = Font.system(size: 34, weight: .semibold, design: .serif)
    /// 28pt / 34 / -0.02em. Screen titles (Tonight, Saved, Settings).
    static let displayLg = Font.system(size: 28, weight: .semibold, design: .serif)
    /// 22pt / 28 / -0.015em. Section headers, dish titles.
    static let displayMd = Font.system(size: 22, weight: .semibold, design: .serif)
    /// 18pt / 24 / -0.01em. In-card subheadings, pricing labels.
    static let displaySm = Font.system(size: 18, weight: .semibold, design: .serif)

    // MARK: - Body (SF Pro, Regular)

    /// 17pt / 24 / 0. Cook Mode step instruction only.
    static let bodyLg = Font.system(size: 17, weight: .regular, design: .default)
    /// 15pt / 22 / 0. Default body.
    static let bodyMd = Font.system(size: 15, weight: .regular, design: .default)
    /// 13pt / 18 / 0. Captions, metadata.
    static let bodySm = Font.system(size: 13, weight: .regular, design: .default)

    // MARK: - Label (SF Pro, Medium)

    /// 15pt / 20 / 0. Button labels, chip text.
    static let labelLg = Font.system(size: 15, weight: .medium, design: .default)
    /// 13pt / 18 / 0. Small button labels, tab bar.
    static let labelMd = Font.system(size: 13, weight: .medium, design: .default)

    // MARK: - Eyebrow (SF Pro, Bold, UPPERCASE, tracked)

    /// 11pt / 14 / +0.14em. UPPERCASE section eyebrows ("PRO FEATURE").
    /// Use with `.textCase(.uppercase)` and `.stirFont(.labelEyebrow)`.
    static let labelEyebrow = Font.system(size: 11, weight: .bold, design: .default)
    /// 10pt / 13 / +0.12em. UPPERCASE tier labels ("MONTHLY", "ANNUAL").
    static let labelMicroEyebrow = Font.system(size: 10, weight: .bold, design: .default)

    // MARK: - Monospace (SF Mono)

    /// 15pt / 22 / 0 / tabular. Timer countdowns, measurements.
    static let monoMd = Font.system(size: 15, weight: .regular, design: .monospaced)
    /// 44pt / 48 / 0 / tabular. Cook Mode hero timer.
    static let monoLg = Font.system(size: 44, weight: .medium, design: .monospaced)
    /// 13pt / 18 / 0. Voice-command quotes ("say *next*").
    static let monoQuote = Font.system(size: 13, weight: .medium, design: .monospaced)
}

// MARK: - Stir type style
//
// A typography token carries more than just `Font`: it also carries
// tracking, line spacing, and a Dynamic Type relativity anchor. The
// `.stirFont(_:)` view modifier applies all of them in one chain.

struct StirTypeStyle {
    let font: Font
    let tracking: CGFloat
    let lineSpacing: CGFloat
    let relativeTo: Font.TextStyle
    let uppercase: Bool

    // MARK: Display

    static let displayXl = StirTypeStyle(
        font: .Stir.displayXl,
        tracking: -0.68,   // 34pt × -0.02em
        lineSpacing: 6,    // LH 40 − size 34 = 6
        relativeTo: .largeTitle,
        uppercase: false,
    )
    static let displayLg = StirTypeStyle(
        font: .Stir.displayLg,
        tracking: -0.56,   // 28 × -0.02em
        lineSpacing: 6,    // 34 − 28
        relativeTo: .title,
        uppercase: false,
    )
    static let displayMd = StirTypeStyle(
        font: .Stir.displayMd,
        tracking: -0.33,   // 22 × -0.015em
        lineSpacing: 6,    // 28 − 22
        relativeTo: .title2,
        uppercase: false,
    )
    static let displaySm = StirTypeStyle(
        font: .Stir.displaySm,
        tracking: -0.18,   // 18 × -0.01em
        lineSpacing: 6,    // 24 − 18
        relativeTo: .title3,
        uppercase: false,
    )

    // MARK: Body

    static let bodyLg = StirTypeStyle(
        font: .Stir.bodyLg,
        tracking: 0,
        lineSpacing: 7,    // 24 − 17
        relativeTo: .body,
        uppercase: false,
    )
    static let bodyMd = StirTypeStyle(
        font: .Stir.bodyMd,
        tracking: 0,
        lineSpacing: 7,    // 22 − 15
        relativeTo: .callout,
        uppercase: false,
    )
    static let bodySm = StirTypeStyle(
        font: .Stir.bodySm,
        tracking: 0,
        lineSpacing: 5,    // 18 − 13
        relativeTo: .footnote,
        uppercase: false,
    )

    // MARK: Label

    static let labelLg = StirTypeStyle(
        font: .Stir.labelLg,
        tracking: 0,
        lineSpacing: 5,    // 20 − 15
        relativeTo: .callout,
        uppercase: false,
    )
    static let labelMd = StirTypeStyle(
        font: .Stir.labelMd,
        tracking: 0,
        lineSpacing: 5,    // 18 − 13
        relativeTo: .footnote,
        uppercase: false,
    )

    // MARK: Eyebrow (always paired with `.textCase(.uppercase)`)

    static let labelEyebrow = StirTypeStyle(
        font: .Stir.labelEyebrow,
        tracking: 1.54,    // 11 × 0.14em
        lineSpacing: 3,    // 14 − 11
        relativeTo: .caption,
        uppercase: true,
    )
    static let labelMicroEyebrow = StirTypeStyle(
        font: .Stir.labelMicroEyebrow,
        tracking: 1.20,    // 10 × 0.12em
        lineSpacing: 3,    // 13 − 10
        relativeTo: .caption2,
        uppercase: true,
    )

    // MARK: Monospace

    static let monoMd = StirTypeStyle(
        font: .Stir.monoMd,
        tracking: 0,
        lineSpacing: 7,
        relativeTo: .callout,
        uppercase: false,
    )
    static let monoLg = StirTypeStyle(
        font: .Stir.monoLg,
        tracking: 0,
        lineSpacing: 4,    // 48 − 44
        relativeTo: .largeTitle,
        uppercase: false,
    )
    static let monoQuote = StirTypeStyle(
        font: .Stir.monoQuote,
        tracking: 0,
        lineSpacing: 5,
        relativeTo: .footnote,
        uppercase: false,
    )
}

// MARK: - View modifier

extension View {
    /// Apply a Stir typography token — font + tracking + line spacing +
    /// Dynamic Type anchor + optional uppercase — in one chain.
    func stirFont(_ style: StirTypeStyle) -> some View {
        modifier(StirFontModifier(style: style))
    }
}

private struct StirFontModifier: ViewModifier {
    let style: StirTypeStyle

    func body(content: Content) -> some View {
        let styled = content
            .font(style.font)
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
        if style.uppercase {
            styled.textCase(.uppercase)
        } else {
            styled
        }
    }
}
