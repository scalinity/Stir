// SelectableChip
//
// User-toggleable pill with two tonal families keyed to the mockup's
// semantic distinction: `.accent` = ember for prefer-positive (diet
// rules, goals, time presets); `.danger` = crimson for prefer-negative
// (dislikes). Used in Setup 1 preferences, ConstraintsSheet time
// presets, SubstitutionSheet ingredient picker.
//
// The selected variant shows an inline checkmark in the label color per
// mockup 02's chip grammar — deliberately distinct from Phase 2's
// `Chip` component (spec §8.2: Selected has no icon). Lifted from
// SetupPreferencesView so ConstraintsSheet + other "select one of N
// preset pills" surfaces can adopt the same grammar without
// duplicating the 70-line state machine. Moved here from
// `Features/Onboarding/SetupPreferencesView.swift` during W-Group-G
// (Form → tokens) per review finding W30.
//
// ## SelectableChip vs Chip — why both exist
//
// See the longer rationale in `Chip.swift` header. TL;DR:
//   - `SelectableChip` = user toggle (capsule, labelLg bold, 44pt).
//     Mockup 02 grammar.
//   - `Chip` = system-assigned status (rounded rect, labelMd, 32pt+).
//     Mockup 04 grammar.
//
// Review finding W13 proposed collapsing the two into one Chip with a
// tonal variant; rejected after implementation audit — the state
// spaces model different concepts (user-chosen vs system-assigned)
// and the visual languages are materially different. Both stay.
//
// WCAG AA-Large 3:1 compliance: selected chips use .bold (weight 700)
// at 15pt (labelLg). ember.600-on-ember.100 and crimson.600-on-
// crimson.100 only hit ~3.67:1 body contrast; 15pt bold qualifies as
// "large" under AA so 3:1 is the applicable threshold (finding C5).
// Idle chips stay at .medium on neutral paper.100 where body contrast
// passes comfortably.

import SwiftUI

struct SelectableChip: View {
    enum Tone { case accent, danger }

    let label: String
    let tone: Tone
    let isSelected: Bool
    let action: () -> Void

    init(
        label: String,
        tone: Tone = .accent,
        isSelected: Bool,
        action: @escaping () -> Void,
    ) {
        self.label = label
        self.tone = tone
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: CGFloat.Stir.space1Half) { // 6pt
                if isSelected {
                    Image.Stir.check
                        .font(.system(size: 12, weight: .semibold)) // justification: sub-icon.sm scale matches mockup 02's inline-check size at 14px on iPhone-size preview
                        .foregroundStyle(foregroundColor)
                }
                Text(label)
                    .stirFont(.labelLg)
                    .fontWeight(isSelected ? .bold : .medium)
                    .foregroundStyle(foregroundColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, CGFloat.Stir.space3Half) // 14pt
            .padding(.vertical, CGFloat.Stir.space2 + 1)   // 9pt
            .background(
                Capsule(style: .continuous).fill(backgroundColor),
            )
            .overlay(
                Capsule(style: .continuous).strokeBorder(borderColor, lineWidth: 1),
            )
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var foregroundColor: Color {
        switch (tone, isSelected) {
        case (.accent, true):   return Color.Stir.ember600
        case (.accent, false):  return Color.Stir.ink700
        case (.danger, true):   return Color.Stir.crimson600
        case (.danger, false):  return Color.Stir.ink700
        }
    }

    private var backgroundColor: Color {
        switch (tone, isSelected) {
        case (.accent, true):   return Color.Stir.ember100
        case (.accent, false):  return Color.Stir.paper100
        case (.danger, true):   return Color.Stir.crimson100
        case (.danger, false):  return Color.Stir.paper100
        }
    }

    private var borderColor: Color {
        switch (tone, isSelected) {
        case (.accent, true):   return Color.Stir.ember600
        case (.accent, false):  return Color.Stir.divider
        case (.danger, true):   return Color.Stir.crimson600
        case (.danger, false):  return Color.Stir.divider
        }
    }
}

// MARK: - Previews

#Preview("SelectableChip — light") {
    chipGallery.preferredColorScheme(.light)
}

#Preview("SelectableChip — dark") {
    chipGallery.preferredColorScheme(.dark)
}

@MainActor
private var chipGallery: some View {
    VStack(alignment: .leading, spacing: CGFloat.Stir.space4) {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            Text("Accent (ember)")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.ink500)
            HStack(spacing: CGFloat.Stir.space2) {
                SelectableChip(label: "Vegan", tone: .accent, isSelected: true, action: {})
                SelectableChip(label: "Paleo", tone: .accent, isSelected: false, action: {})
            }
        }
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            Text("Danger (crimson)")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.ink500)
            HStack(spacing: CGFloat.Stir.space2) {
                SelectableChip(label: "Cilantro", tone: .danger, isSelected: true, action: {})
                SelectableChip(label: "Olives", tone: .danger, isSelected: false, action: {})
            }
        }
    }
    .padding(CGFloat.Stir.space4)
    .background(Color.Stir.paper50)
}
