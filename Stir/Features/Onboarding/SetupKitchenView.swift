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
//   - 3-col equipment grid with simplified glyphs (see GLYPH NOTE below)
//   - Servings stepper: minus / mono 36pt count / plus (ember filled)
//   - PrimaryButton "Set up my kitchen" in footer with disclosure chevron
//
// GLYPH NOTE: Mockup 02 uses per-equipment line-art SVGs (oven frame,
// stove burners, pan outline, etc.). Reproducing 16 bespoke SwiftUI
// Canvas paths is deferred — Design-System.md §13 scopes a custom
// icon set to v2. v1 tile glyph is `fork.knife` across all codes;
// visual variety is deliberately flattened in favor of the explicit
// text label underneath each tile (accessibility-positive: label
// carries semantic, not the glyph). Selected state flips glyph +
// label to ember.

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

    private var equipmentGrid: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: CGFloat.Stir.space3 - 2), // 10pt
            count: 3,
        )
        return LazyVGrid(columns: columns, spacing: CGFloat.Stir.space3 - 2) {
            ForEach(KitchenEquipment.CommonCode.allCases, id: \.self) { code in
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
                Image.Stir.fork
                    .font(.system(size: CGFloat.Stir.iconLg, weight: .regular))
                    .foregroundStyle(
                        isSelected ? Color.Stir.ember600 : Color.Stir.ink500,
                    )
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

// Previews deferred to preview-infrastructure pass (see note in
// SetupPreferencesView.swift).
