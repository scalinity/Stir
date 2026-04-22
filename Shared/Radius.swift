// Radius.swift
//
// Stir corner-radius tokens — mirrors Specs/Design-System.md §5.4.
// Expanded from the pre-mockup 5-token scale to the 8-token scale the
// mockups actually use. Default cards are 14pt; hero cards are 16pt;
// modals are 22pt; sheet tops are 24pt.
//
// Usage: `CGFloat.Stir.radiusCard`, `CGFloat.Stir.radiusFull`.

import CoreGraphics

extension CGFloat.Stir {
    // MARK: - Scale

    /// 8pt — chips, small tags.
    static let radiusSm: CGFloat = 8
    /// 12pt — buttons, input fields, pricing tiles.
    static let radiusMd: CGFloat = 12
    /// 14pt — default card surface (Tonight, Solve, Saved, Settings).
    /// Dominant card radius across the app.
    static let radiusCard: CGFloat = 14
    /// 16pt — hero cards only (`DishOptionCard`, `SavedMealCard` primary,
    /// premium gradient card).
    static let radiusLg: CGFloat = 16
    /// 18pt — elevated accent cards (inline paywall card, emphasized
    /// inline blocks with decorative corner glow).
    static let radiusAccent: CGFloat = 18
    /// 22pt — centered modals (voice paywall, substitution result).
    static let radiusXl: CGFloat = 22
    /// 24pt — bottom-sheet top corners (iOS `.medium` detent).
    static let radiusSheet: CGFloat = 24
    /// 999pt — pill controls, mic button, avatar circles.
    static let radiusFull: CGFloat = 999
}
