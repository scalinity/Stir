// Colors.swift
//
// Stir color tokens — the single source of truth for every hex in the app.
// Mirrors Specs/Design-System.md §3 and the mockup palette in
// stir-app-design/project/DesignMockups/_shared/colors_and_type.css.
//
// Light and dark values resolve automatically via UITraitCollection.
// Never reference a hex outside this file. Lint rule:
//   grep -rE '#[0-9A-Fa-f]{6}' Stir/Features/  →  zero matches.
//
// Usage: `Color.Stir.ember600`, `Color.Stir.ink900`, `Color.Stir.paperSurface`.

import SwiftUI
import UIKit

extension Color {
    enum Stir {}
}

extension Color.Stir {
    // MARK: - Ink (text + high-stakes UI)

    /// Primary text, high-stakes UI. Light `#1A1612` / Dark `#F5F0E8`.
    static let ink900 = dualColor(light: 0x1A1612, dark: 0xF5F0E8)
    /// Secondary text. Light `#3D342C` / Dark `#D6CEC3`.
    static let ink700 = dualColor(light: 0x3D342C, dark: 0xD6CEC3)
    /// Tertiary text, captions. Light `#6B5F54` / Dark `#9A8F84`.
    static let ink500 = dualColor(light: 0x6B5F54, dark: 0x9A8F84)
    /// Disabled text, placeholder. Light `#A89E93` / Dark `#5E5349`.
    static let ink300 = dualColor(light: 0xA89E93, dark: 0x5E5349)
    /// Dividers, hairlines. Light `#E8E3DD` / Dark `#2E2822`.
    static let ink100 = dualColor(light: 0xE8E3DD, dark: 0x2E2822)

    // MARK: - Paper (warm off-white backgrounds)

    /// Primary screen background. Light `#FAF7F2` / Dark `#14100B`.
    static let paper50 = dualColor(light: 0xFAF7F2, dark: 0x14100B)
    /// Card surface. Light `#F3EEE5` / Dark `#1F1A14`.
    static let paper100 = dualColor(light: 0xF3EEE5, dark: 0x1F1A14)
    /// Grouped list, tertiary surface. Light `#EBE3D6` / Dark `#2A241C`.
    static let paper200 = dualColor(light: 0xEBE3D6, dark: 0x2A241C)

    // MARK: - Ember (primary action family)

    /// Primary action fill. Light `#C8532B` / Dark `#E26340`.
    static let ember600 = dualColor(light: 0xC8532B, dark: 0xE26340)
    /// Hover / pressed ember. Light `#E26340` / Dark `#F07D5A`.
    static let ember500 = dualColor(light: 0xE26340, dark: 0xF07D5A)
    /// Ember tint — selected chip, subtle highlight.
    /// Light `#FBEAE0` / Dark `#3A1E13`.
    static let ember100 = dualColor(light: 0xFBEAE0, dark: 0x3A1E13)
    /// Deep ember — gradient-stop ONLY, never a flat fill. Paired with
    /// `ember600` on premium/Pro emphasis cards.
    /// Light `#8F3B1D` / Dark `#C8532B`.
    static let ember700 = dualColor(light: 0x8F3B1D, dark: 0xC8532B)

    // MARK: - Sage (success / positive)

    /// Success, confirmed, completed. Light `#3E6849` (deepened from
    /// step-9 `#4A7C59` to reach WCAG AA body 4.5:1 on `sage.100` —
    /// the previous value hit only ~3.75:1 on 13pt regular, failing
    /// on DishOptionCard "You have it all" + FitLabel `.leastWaste`
    /// + confirmed-confidence chip. Review finding C5.)
    /// Dark `#6FA07C` unchanged — clears ~4.9:1 on dark sage.100.
    static let sage600 = dualColor(light: 0x3E6849, dark: 0x6FA07C)
    /// Sage tint. Light `#E4EEE6` / Dark `#1E2E23`.
    static let sage100 = dualColor(light: 0xE4EEE6, dark: 0x1E2E23)

    // MARK: - Amber (warning / needs attention)

    /// Pending review, low-confidence chip, billing-grace banner.
    /// Light `#7A5908` (deepened from step-9 `#B8860B` to reach WCAG
    /// AA body contrast 4.5:1 on `amber.100` — the previous value hit
    /// only 2.70:1 which failed 13pt regular body on warning banners,
    /// fit labels, and billing copy. See review finding C5.)
    /// Dark `#D4A21F` unchanged — already clears ~6.4:1 on dark amber.100.
    static let amber600 = dualColor(light: 0x7A5908, dark: 0xD4A21F)
    /// Amber tint. Light `#F5ECD5` / Dark `#2E2614`.
    static let amber100 = dualColor(light: 0xF5ECD5, dark: 0x2E2614)

    // MARK: - Crimson (hard-rule / allergen)

    /// Allergen, dietary breach, hard-rule block. Always paired with
    /// the `.allergen` SF Symbol, never color-alone.
    /// Light `#9A2E2E` / Dark `#C94747`.
    static let crimson600 = dualColor(light: 0x9A2E2E, dark: 0xC94747)
    /// Crimson tint. Light `#F2DCDC` / Dark `#2E1818`.
    static let crimson100 = dualColor(light: 0xF2DCDC, dark: 0x2E1818)

    // MARK: - Rust (soft recoverable error)

    /// Soft recoverable error — OCR couldn't read, low-confidence parse.
    /// Distinct from `crimson600` (hard breach) and `amber600` (pending).
    /// Folds to the dark ember hue on dark mode.
    /// Light `#A8441F` / Dark `#E26340`.
    static let rust600 = dualColor(light: 0xA8441F, dark: 0xE26340)

    // MARK: - Voice (quarantined — Cook Mode voice UI only)

    /// Voice mode accent — mic-active glow, Live Activity, voice-only state.
    /// Never use elsewhere.
    /// Light `#5E4AE0` / Dark `#8473E8`.
    static let voice600 = dualColor(light: 0x5E4AE0, dark: 0x8473E8)
    /// Voice tint. Light `#E8E3FA` / Dark `#1F1A33`.
    static let voice100 = dualColor(light: 0xE8E3FA, dark: 0x1F1A33)

    // MARK: - Shadow companion colors (soft-press 3D button effect)

    /// Shadow fill for the "soft-press" 3D button y-offset shadow.
    /// Not a text/fill color — only used inside `Shadow.Stir.softPress`.
    /// Light `#E8E1D4` / Dark `#2A2520`.
    static let pressShadow = dualColor(light: 0xE8E1D4, dark: 0x2A2520)

    // MARK: - Semantic aliases
    //
    // Prefer semantic names at the view layer; they survive palette
    // adjustments without renaming call sites.

    /// Primary text color alias — same resolution as `ink900`.
    static let textPrimary = ink900
    /// Secondary text alias — `ink700`.
    static let textSecondary = ink700
    /// Tertiary / caption text alias — `ink500`.
    static let textTertiary = ink500
    /// Disabled / placeholder text — `ink300`.
    static let textDisabled = ink300

    /// Screen background alias — `paper50`.
    static let backgroundPrimary = paper50
    /// Card surface background alias — `paper100`.
    static let backgroundCard = paper100
    /// Grouped list background alias — `paper200`.
    static let backgroundGrouped = paper200

    /// Divider / hairline alias — `ink100`.
    static let divider = ink100

    /// Primary brand action alias — `ember600`.
    static let accent = ember600
    /// Semantic success alias — `sage600`.
    static let success = sage600
    /// Semantic warning alias — `amber600`.
    static let warning = amber600
    /// Semantic critical alias — `crimson600`.
    static let danger = crimson600
    /// Semantic soft-error alias — `rust600`.
    static let softError = rust600
}

// MARK: - Dual-color helper
//
// Resolves the correct hex per UITraitCollection.userInterfaceStyle.
// One function, every token. No `@Environment(\.colorScheme)` plumbing
// needed at the view layer.

private func dualColor(light: UInt32, dark: UInt32) -> Color {
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(rgb: dark)
            : UIColor(rgb: light)
    })
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0,
        )
    }
}
