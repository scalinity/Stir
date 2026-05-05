// SetupKitchenView
//
// Step 2 of onboarding (mockup 02 §"Setup 2 — Kitchen & Servings").
// Equipment 3-column tappable grid + servings stepper. "Finish setup"
// in footer pushes `.completionTransition` route (wired in OnboardingRoot
// — this view just calls its `onComplete` closure).
//
// Visual grammar (mockup 02):
//   - Custom nav header: Back / progress dots / Skip (same as Setup 1)
//   - Ember labelEyebrow "STEP 2 OF 2"
//   - displayLg title "What's your kitchen like?"
//   - bodyMd subtitle
//   - 3-col equipment grid with bespoke per-code line-art glyphs
//   - Servings stepper: minus / mono 36pt count / plus (ember filled)
//   - PrimaryButton "Set up my kitchen" in footer with disclosure chevron
//
// GLYPH NOTE: Per mockup 02, each equipment tile carries a distinct
// line-art glyph (oven frame, stove burners, pan outline, etc.) drawn
// as bespoke SwiftUI `Path`s in `EquipmentGlyph` below. Strokes scale
// with `iconLg`-sized frame and inherit the ember/ink-500 selected
// vs idle color. `fork.knife` placeholder used in step 4 has been
// retired; if a future code lacks a Path mapping, the Path falls
// through to a generic rectangle so the tile still renders.

import SwiftUI

struct SetupKitchenView: View {
    @Bindable var viewModel: OnboardingViewModel
    let onBack: () -> Void
    let onComplete: () -> Void
    let onSkip: () -> Void

    /// Scales the 36pt servings-stepper numeral with Dynamic Type.
    /// Review finding W-F W25 (FD1).
    @ScaledMetric(relativeTo: .largeTitle) private var servingsNumeralSize: CGFloat = 36

    init(
        viewModel: OnboardingViewModel,
        onBack: @escaping () -> Void = {},
        onComplete: @escaping () -> Void,
        onSkip: @escaping () -> Void = {},
    ) {
        self.viewModel = viewModel
        self.onBack = onBack
        self.onComplete = onComplete
        self.onSkip = onSkip
    }

    var body: some View {
        VStack(spacing: 0) {
            navHeader
            scrollingBody
            footer
        }
        .background(Color.Stir.paper50)
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - Sections

    private var navHeader: some View {
        HStack(alignment: .center) {
            Button(action: onBack) {
                HStack(spacing: CGFloat.Stir.space1 / 2) { // 2pt
                    Image.Stir.back
                        .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                    Text("Back")
                        .stirFont(.labelLg)
                }
                .foregroundStyle(Color.Stir.ember600)
                .frame(minHeight: 44)
                .padding(.horizontal, CGFloat.Stir.space1 + 2) // 6pt
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Back to preferences")

            Spacer()
            OnboardingProgressDots(current: 2, total: 2)
            Spacer()

            Button(action: onSkip) {
                Text("Skip")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Skip onboarding")
        }
        .padding(.horizontal, CGFloat.Stir.space3) // 12pt
        .padding(.top, CGFloat.Stir.space2)
        .padding(.bottom, CGFloat.Stir.space3 - 2) // 10pt
    }

    private var scrollingBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space5) { // 24pt
                stepHeader
                equipmentGrid
                servingsStepper
            }
            .padding(.horizontal, CGFloat.Stir.screenMarginHero)
            .padding(.top, CGFloat.Stir.space2)
            .padding(.bottom, CGFloat.Stir.space5)
        }
    }

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
            Text("Step 2 of 2")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.ember600)

            Text("What's your kitchen like?")
                .stirFont(.displayLg)
                .foregroundStyle(Color.Stir.ink900)
                .accessibilityAddTraits(.isHeader)

            Text("Tap what you have. I'll never suggest a recipe that needs something you don't.")
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink500)
        }
    }

    /// Curated 9-item subset rendered by mockup 02 Setup-2 onboarding,
    /// in the exact order the mockup lays out. Settings preferences
    /// (HouseholdPreferencesView) keeps `.allCases` for full power-user
    /// editability; this array is the onboarding's first-touch curation.
    /// Lives here rather than on `KitchenEquipment.CommonCode` because
    /// it's a UI-curation concern, not a property of the data model.
    private static let curatedEquipment: [KitchenEquipment.CommonCode] = [
        .oven, .stovetop, .sheetPan,
        .skillet, .dutchOven, .blender,
        .airFryer, .microwave, .rice_cooker,
    ]

    private var equipmentGrid: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: CGFloat.Stir.space3 - 2), // 10pt
            count: 3,
        )
        return LazyVGrid(columns: columns, spacing: CGFloat.Stir.space3 - 2) {
            ForEach(Self.curatedEquipment, id: \.self) { code in
                EquipmentTile(
                    code: code,
                    isSelected: viewModel.selectedEquipment.contains(code),
                    action: {
                        if viewModel.selectedEquipment.contains(code) {
                            viewModel.selectedEquipment.remove(code)
                        } else {
                            viewModel.selectedEquipment.insert(code)
                        }
                    },
                )
            }
        }
    }

    private var servingsStepper: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space1 / 2) {
                Text("Usual servings")
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.ink700)
                Text("Default servings for solves. Scale per recipe later.")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
            }

            HStack {
                ServingsButton(
                    direction: .decrement,
                    isDisabled: viewModel.servingsDefault <= 1,
                    action: {
                        guard viewModel.servingsDefault > 1 else { return }
                        viewModel.servingsDefault -= 1
                    },
                )

                Spacer()

                VStack(spacing: CGFloat.Stir.space1) {
                    // justification: 36pt mono hero numeral is a
                    // one-off per §4.1 — scaling stepper count has
                    // different presence needs than the `.monoLg` 44pt
                    // Cook Mode timer, so it's bespoke.
                    Text("\(viewModel.servingsDefault)")
                        // justification: 36pt mono hero numeral for the servings stepper — one-off per §4.1 (see multi-line comment above), scaled via @ScaledMetric
                        .font(.system(size: servingsNumeralSize, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Color.Stir.ink900)
                    Text(viewModel.servingsDefault == 1 ? "serving" : "servings")
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.ink500)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(viewModel.servingsDefault) \(viewModel.servingsDefault == 1 ? "serving" : "servings")")

                Spacer()

                ServingsButton(
                    direction: .increment,
                    isDisabled: viewModel.servingsDefault >= 12,
                    action: {
                        guard viewModel.servingsDefault < 12 else { return }
                        viewModel.servingsDefault += 1
                    },
                )
            }
            .padding(CGFloat.Stir.space3)
            .stirCard()
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color.Stir.divider)
            PrimaryButton(
                title: "Set up my kitchen",
                isDisabled: !viewModel.canCompleteKitchenStep,
                action: onComplete,
            )
            .padding(.horizontal, CGFloat.Stir.screenMarginHero)
            .padding(.top, CGFloat.Stir.space4)
            .padding(.bottom, CGFloat.Stir.space5)
        }
    }
}

// MARK: - EquipmentTile

private struct EquipmentTile: View {
    let code: KitchenEquipment.CommonCode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: CGFloat.Stir.space2) {
                EquipmentGlyph(code: code, isSelected: isSelected)
                    .accessibilityHidden(true)

                Text(code.displayName)
                    .stirFont(.bodySm)
                    .fontWeight(.medium)
                    .foregroundStyle(
                        isSelected ? Color.Stir.ember600 : Color.Stir.ink700,
                    )
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, CGFloat.Stir.space2)
            .padding(.vertical, CGFloat.Stir.space3Half) // 14pt
            .stirCard(
                fill: isSelected ? Color.Stir.ember100 : Color.Stir.paper100,
                borderColor: isSelected ? Color.Stir.ember600 : Color.Stir.divider,
            )
            .frame(minHeight: 80)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(code.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - ServingsButton

private struct ServingsButton: View {
    enum Direction { case increment, decrement }
    let direction: Direction
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            icon
                .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: 44, height: 44)
                .background(background)
                .overlay(
                    RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                        .strokeBorder(
                            direction == .decrement ? Color.Stir.divider : Color.clear,
                            lineWidth: 1,
                        ),
                )
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1.0)
        .accessibilityLabel(
            direction == .increment ? "Increase servings" : "Decrease servings",
        )
    }

    private var icon: Image {
        direction == .increment ? Image.Stir.plus : Image.Stir.minus
    }

    private var foregroundColor: Color {
        direction == .increment ? Color.Stir.paper50 : Color.Stir.ink700
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
            .fill(direction == .increment ? Color.Stir.ember600 : Color.Stir.paper50)
    }
}

// MARK: - EquipmentGlyph
//
// Bespoke per-code line-art glyphs matching mockup 02's 28×28 SVGs.
// `EquipmentShape` rasterizes the path geometry per `CommonCode`; the
// wrapper view applies the selected/idle stroke color. Codes outside
// the curated 9 fall through to a generic rectangle so the tile still
// renders (Settings preferences may surface other codes).

private struct EquipmentGlyph: View {
    let code: KitchenEquipment.CommonCode
    let isSelected: Bool

    var body: some View {
        EquipmentShape(code: code)
            .stroke(
                isSelected ? Color.Stir.ember600 : Color.Stir.ink500,
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round),
            )
            .frame(width: CGFloat.Stir.iconLg, height: CGFloat.Stir.iconLg) // 28pt
    }
}

private struct EquipmentShape: Shape {
    let code: KitchenEquipment.CommonCode

    func path(in rect: CGRect) -> Path {
        // Mockup glyphs are authored against a 28-unit viewBox. Scale
        // every coordinate by `s` so the same numeric paths render
        // correctly inside any frame size.
        let s = min(rect.width, rect.height) / 28.0
        var p = Path()
        let pt: (CGFloat, CGFloat) -> CGPoint = { x, y in
            CGPoint(x: x * s, y: y * s)
        }

        switch code {
        case .oven:
            // 20×20 rounded body + horizontal divider + 2 short knobs.
            p.addRoundedRect(
                in: CGRect(x: 4 * s, y: 4 * s, width: 20 * s, height: 20 * s),
                cornerSize: CGSize(width: 2 * s, height: 2 * s),
            )
            p.move(to: pt(4, 10));  p.addLine(to: pt(24, 10))
            p.move(to: pt(8, 14));  p.addLine(to: pt(14, 14))
            p.move(to: pt(18, 14)); p.addLine(to: pt(20, 14))

        case .stovetop:
            // 4 burner circles in a 2×2 arrangement.
            for (cx, cy) in [(10, 10), (18, 10), (10, 18), (18, 18)] {
                let r = 3.5 * s
                p.addEllipse(in: CGRect(
                    x: CGFloat(cx) * s - r, y: CGFloat(cy) * s - r,
                    width: 2 * r, height: 2 * r,
                ))
            }

        case .sheetPan:
            // Wide rounded rectangle with a short handle protruding right.
            p.addRoundedRect(
                in: CGRect(x: 4 * s, y: 10 * s, width: 16 * s, height: 10 * s),
                cornerSize: CGSize(width: 1 * s, height: 1 * s),
            )
            p.move(to: pt(20, 14)); p.addLine(to: pt(24, 14))

        case .skillet:
            // Round skillet body with horizontal handle.
            let r = 7 * s
            p.addEllipse(in: CGRect(
                x: 12 * s - r, y: 14 * s - r, width: 2 * r, height: 2 * r,
            ))
            p.move(to: pt(19, 14)); p.addLine(to: pt(25, 14))

        case .dutchOven:
            // Body — open at top (left wall, rounded bottom corners,
            // right wall). The `lid line` below provides the visible
            // top edge; closing the subpath would draw an overlapping
            // stroke on the (5,9)–(23,9) span.
            p.move(to: pt(5, 9))
            p.addLine(to: pt(5, 18))
            p.addQuadCurve(to: pt(8, 21), control: pt(5, 21))
            p.addLine(to: pt(20, 21))
            p.addQuadCurve(to: pt(23, 18), control: pt(23, 21))
            p.addLine(to: pt(23, 9))
            // Lid line (handle bar) — extends 2 units beyond body on
            // each side so it reads as a separate lid resting on top.
            p.move(to: pt(3, 9));  p.addLine(to: pt(25, 9))
            // Lid knobs.
            p.move(to: pt(9, 6));  p.addLine(to: pt(9, 9))
            p.move(to: pt(19, 6)); p.addLine(to: pt(19, 9))

        case .blender:
            // Trapezoid lid + rectangular cup.
            p.move(to: pt(10, 3))
            p.addLine(to: pt(18, 3))
            p.addLine(to: pt(17, 9))
            p.addLine(to: pt(11, 9))
            p.closeSubpath()
            p.addRoundedRect(
                in: CGRect(x: 8 * s, y: 12 * s, width: 12 * s, height: 11 * s),
                cornerSize: CGSize(width: 2 * s, height: 2 * s),
            )

        case .airFryer:
            // Tall rounded body + viewport circle + base bar.
            p.addRoundedRect(
                in: CGRect(x: 6 * s, y: 4 * s, width: 16 * s, height: 20 * s),
                cornerSize: CGSize(width: 2 * s, height: 2 * s),
            )
            let viewportR = 3 * s
            p.addEllipse(in: CGRect(
                x: 14 * s - viewportR, y: 12 * s - viewportR,
                width: 2 * viewportR, height: 2 * viewportR,
            ))
            p.move(to: pt(10, 20)); p.addLine(to: pt(18, 20))

        case .microwave:
            // Outer body + viewing window + tiny indicator dot.
            p.addRoundedRect(
                in: CGRect(x: 3 * s, y: 6 * s, width: 22 * s, height: 16 * s),
                cornerSize: CGSize(width: 2 * s, height: 2 * s),
            )
            p.addRect(CGRect(x: 5 * s, y: 8 * s, width: 12 * s, height: 12 * s))
            let dotR = 0.8 * s
            p.addEllipse(in: CGRect(
                x: 21 * s - dotR, y: 12 * s - dotR,
                width: 2 * dotR, height: 2 * dotR,
            ))

        case .rice_cooker:
            // Lid line on top, rounded pot body below, lid knob.
            p.move(to: pt(5, 10));  p.addLine(to: pt(23, 10))
            p.move(to: pt(7, 10))
            p.addLine(to: pt(7, 20))
            p.addQuadCurve(to: pt(9, 22), control: pt(7, 22))
            p.addLine(to: pt(19, 22))
            p.addQuadCurve(to: pt(21, 20), control: pt(21, 22))
            p.addLine(to: pt(21, 10))
            let knobR = 2 * s
            p.addEllipse(in: CGRect(
                x: 14 * s - knobR, y: 6 * s - knobR,
                width: 2 * knobR, height: 2 * knobR,
            ))

        default:
            // Fallback for codes outside the mockup's curated 9 — a
            // simple rounded rectangle keeps the tile visually whole.
            p.addRoundedRect(
                in: CGRect(x: 4 * s, y: 6 * s, width: 20 * s, height: 16 * s),
                cornerSize: CGSize(width: 2 * s, height: 2 * s),
            )
        }
        return p
    }
}

// Previews deferred to preview-infrastructure pass (see note in
// SetupPreferencesView.swift).
