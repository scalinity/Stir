// StirPlate
//
// Unified plate illustration (SCA-96). Replaces two private duplicates:
//
//   - `Stir/Features/Tonight/TonightHomeView.swift` → `PlateIllustration`
//     (mockup 03's hero plate — full salmon fillet + greens + lemon +
//     rice + sesame).
//   - `Stir/DesignSystem/Components/DishOptionCard.swift` → `PlateView`
//     (mockup 05's abstract option plate — main + 2 accent dots + rice).
//
// The two mockups are intentionally distinct visual treatments: mockup
// 05's `Plate` is even commented in the source HTML as the "smaller
// variant than 03". Pixel-truth wins (mockup precedence rule §0), so
// the unification is via a Variant enum that hosts both treatments
// rather than a single shape parameterised by colour alone.
//
// Variants:
//   - `.hero` — full mockup-03 hero plate. Salmon fillet, three sage
//     greens, one lemon wedge, 14 rice grains, 3 sesame seeds. Used by
//     `TonightPickHeroCard`. SCA-311 S5: previously parameterized by a
//     single-case `HeroTint` enum; collapsed since only `.salmon`
//     shipped. Re-introduce the enum if/when a second protein tint
//     ships — the migration is mechanical (re-add the enum, add a
//     `tint:` associated value, route through `HeroPlate`).
//   - `.option(tint: OptionTint)` — mockup-05 abstract option plate.
//     Main centre dot keyed off ordinal rank; two accent dots; one
//     dark dot; 10 rice grains. Used by `DishOptionCard`, where
//     `OptionTint` cycles by `rank` (1 → .salmon, 2 → .sage, 3 → .amber).
//
// FD1-11 follow-up: the prior TonightHomeView variant wrapped the
// fillet-grain `Path` in a `GeometryReader { _ in … }` whose size was
// hard-coded to the surrounding ZStack frame. The reader added an
// extra layout pass for nothing — the `size` is already a constructor
// parameter, so this implementation drops the GeometryReader and
// computes the path constants directly. Visual output is identical.

import SwiftUI

struct StirPlate: View {
    enum Variant {
        case hero
        case option(tint: OptionTint)
    }

    /// Option-plate tints, cycled by rank in `DishOptionCard`. Each tint
    /// exposes a main + two accent colours. The mockup hard-coded
    /// `sage + amber` accents on every tint, which on the sage and
    /// amber main plates collapsed one accent into the main colour and
    /// rendered it invisible — so the per-tint palette here keeps both
    /// accent dots visible against every main colour.
    enum OptionTint {
        case salmon, sage, amber

        var mainColor: Color {
            switch self {
            case .salmon: return Color.Stir.ember600
            case .sage: return Color.Stir.sage600
            case .amber: return Color.Stir.amber600
            }
        }

        /// Upper-left, larger accent (mockup's "sage spot" position).
        var accent1Color: Color {
            switch self {
            case .salmon: return Color.Stir.sage600
            case .sage: return Color.Stir.amber600 // avoid sage-on-sage
            case .amber: return Color.Stir.sage600
            }
        }

        /// Upper-right, smaller accent (mockup's "amber spot" position).
        var accent2Color: Color {
            switch self {
            case .salmon: return Color.Stir.amber600
            case .sage: return Color.Stir.amber600
            case .amber: return Color.Stir.ember600 // avoid amber-on-amber
            }
        }
    }

    let variant: Variant
    let size: CGFloat

    init(_ variant: Variant, size: CGFloat) {
        self.variant = variant
        self.size = size
    }

    var body: some View {
        Group {
            switch variant {
            case .hero:
                HeroPlate(size: size)
            case let .option(tint):
                OptionPlate(size: size, tint: tint)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Hero variant (mockup 03)

private struct HeroPlate: View {
    let size: CGFloat

    /// Salmon fillet colour. Inlined from the retired `HeroTint.salmon`
    /// seam (SCA-311 S5). When a second protein tint ships, restore the
    /// enum and thread `tint: HeroTint` through here.
    private var filletColor: Color { Color.Stir.ember600 }

    var body: some View {
        ZStack {
            // Outer disc
            Circle()
                .fill(Color.Stir.paper200)
                .overlay(Circle().strokeBorder(Color.Stir.divider, lineWidth: 1))
                .frame(width: size, height: size)

            // Inner disc — slightly smaller for the rim effect
            Circle()
                .fill(Color.Stir.paper100)
                .overlay(Circle().strokeBorder(Color.Stir.divider, lineWidth: 1))
                .frame(width: size * 0.86, height: size * 0.86)

            // Protein fillet — rounded ovoid in tint at 88% opacity,
            // overlaid with three pale grain lines.
            Capsule(style: .continuous)
                .fill(filletColor.opacity(0.88))
                .frame(width: size * 0.40, height: size * 0.26)
                .rotationEffect(.degrees(-8))
                .offset(x: -size * 0.07, y: size * 0.02)
                .overlay(
                    // FD1-11: GeometryReader retired — the path is fully
                    // size-derived, no parent-frame measurement needed.
                    Path { p in
                        let w = size * 0.30
                        let h = size * 0.18
                        let originX = (size * 0.40 - w) / 2
                        let originY = (size * 0.26 - h) / 2 + size * 0.02
                        for i in 0..<3 {
                            let yOffset = originY + CGFloat(i) * (h / 3)
                            p.move(to: CGPoint(x: originX, y: yOffset))
                            p.addQuadCurve(
                                to: CGPoint(x: originX + w, y: yOffset),
                                control: CGPoint(x: originX + w / 2, y: yOffset - 2),
                            )
                        }
                    }
                    .stroke(Color.Stir.ember100, lineWidth: 1.2)
                    .frame(width: size * 0.40, height: size * 0.26)
                    .rotationEffect(.degrees(-8))
                    .offset(x: -size * 0.07, y: size * 0.02),
                )

            // Sage greens — three soft circles stacked top-right
            Circle()
                .fill(Color.Stir.sage600.opacity(0.80))
                .frame(width: size * 0.10, height: size * 0.10)
                .offset(x: size * 0.21, y: -size * 0.08)
            Circle()
                .fill(Color.Stir.sage600.opacity(0.90))
                .frame(width: size * 0.07, height: size * 0.07)
                .offset(x: size * 0.27, y: -size * 0.02)
            Circle()
                .fill(Color.Stir.sage600.opacity(0.75))
                .frame(width: size * 0.08, height: size * 0.08)
                .offset(x: size * 0.22, y: size * 0.05)

            // Lemon wedge — amber circle with dashed rim (pith hint)
            Circle()
                .fill(Color.Stir.amber600.opacity(0.85))
                .overlay(
                    Circle().strokeBorder(
                        Color.Stir.paper50.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: [2, 2]),
                    ),
                )
                .frame(width: size * 0.09, height: size * 0.09)
                .offset(x: size * 0.16, y: size * 0.15)

            // Rice grains — 14 small ellipses below the fillet
            riceGrains

            // Sesame seeds — 3 dark dots on the salmon
            sesameSeeds
        }
        .frame(width: size, height: size)
    }

    private var riceGrains: some View {
        ZStack {
            ForEach(0..<14, id: \.self) { i in
                let col = i % 5
                let row = i / 5
                let x = -size * 0.11 + CGFloat(col) * (size * 0.03) + CGFloat(row % 2) * (size * 0.015)
                let y = size * 0.20 + CGFloat(row) * (size * 0.025)
                Ellipse()
                    .fill(Color.Stir.divider)
                    .opacity(0.7)
                    .frame(width: size * 0.025, height: size * 0.015)
                    .offset(x: x, y: y)
            }
        }
    }

    private var sesameSeeds: some View {
        ZStack {
            Circle()
                .fill(Color.Stir.ink700)
                .frame(width: size * 0.012, height: size * 0.012)
                .offset(x: -size * 0.06, y: -size * 0.02)
            Circle()
                .fill(Color.Stir.ink700)
                .frame(width: size * 0.012, height: size * 0.012)
                .offset(x: size * 0.02, y: 0)
            Circle()
                .fill(Color.Stir.ink700)
                .frame(width: size * 0.012, height: size * 0.012)
                .offset(x: size * 0.07, y: -size * 0.03)
        }
    }
}

// MARK: - Option variant (mockup 05)

private struct OptionPlate: View {
    let size: CGFloat
    let tint: StirPlate.OptionTint

    var body: some View {
        // Mockup 05's plate is drawn against a 200×200 viewBox, so every
        // dimension is scaled by `s = size / 200` to keep proportions
        // identical at any caller-supplied `size`.
        let s = size / 200.0
        ZStack {
            Circle()
                .fill(Color.Stir.paper200)
                .frame(width: 176 * s, height: 176 * s)
            Circle()
                .fill(Color.Stir.paper100)
                .frame(width: 152 * s, height: 152 * s)
            Circle()
                .fill(tint.mainColor.opacity(0.85))
                .frame(width: 88 * s, height: 88 * s)
            Circle()
                .fill(tint.accent1Color.opacity(0.75))
                .frame(width: 24 * s, height: 24 * s)
                .offset(x: -28 * s, y: -6 * s)
            Circle()
                .fill(tint.accent2Color.opacity(0.85))
                .frame(width: 20 * s, height: 20 * s)
                .offset(x: 32 * s, y: -4 * s)
            Circle()
                .fill(Color.Stir.ink700.opacity(0.35))
                .frame(width: 18 * s, height: 18 * s)
                .offset(x: 20 * s, y: 28 * s)
        }
        .frame(width: size, height: size)
    }
}

#if DEBUG
#Preview("StirPlate — variants") {
    HStack(spacing: CGFloat.Stir.space4) {
        StirPlate(.hero, size: 180)
        VStack(spacing: CGFloat.Stir.space3) {
            StirPlate(.option(tint: .salmon), size: 88)
            StirPlate(.option(tint: .sage), size: 88)
            StirPlate(.option(tint: .amber), size: 88)
        }
    }
    .padding(CGFloat.Stir.space4)
    .background(Color.Stir.paper50)
}
#endif
