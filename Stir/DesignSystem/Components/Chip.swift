// Chip
//
// Small pill used to surface a system-assigned status on a label —
// primarily Scan Review (confidence signals on AI-parsed ingredients)
// and mockup-04 chip grids. Spec §8.2 defines six visual states; this
// component models them via a ChipState enum.
//
// States:
//   - `.normal`              → paper.100 fill, ink.700 label, divider
//                              border (unselected resting)
//   - `.selected`            → ember.100 fill, ember.600 label+border
//                              (included for symmetry with other pills
//                              — production toggle UI uses
//                              `SelectableChip` instead; see below)
//   - `.confidenceConfirmed` → default + sage.600 checkmark
//   - `.confidenceReview`    → amber.100 fill, amber.600 label, amber
//                              questionmark (AI flagged for review)
//   - `.likelyStaple`        → default + ink.500 text (lowest emphasis
//                              — the model is fairly sure but the user
//                              should confirm staples like salt)
//   - `.allergenWarning`     → crimson.100 fill, crimson.600 label,
//                              crimson allergen triangle (hard rule)
//
// ## Chip vs SelectableChip — why both exist
//
// `Chip` here models "what the system knows about this label" — it's
// the confidence surface. State encodes semantic (AI verdict, allergen
// hazard, staple status), not user toggle position.
//
// `SelectableChip` (DesignSystem/Components/SelectableChip.swift)
// models "what the user has chosen" — toggle UI on onboarding Setup 1,
// ConstraintsSheet time presets, SubstitutionSheet ingredient picker.
// It's a Capsule pill (not a rounded rect), renders .labelLg bold at
// 44pt, and carries a .accent/.danger tonal distinction. Visual
// grammar per mockup 02 differs intentionally from mockup 04's
// confidence chips — the two components serve different design intents
// and sharing a base type would force compromise on one or the other.
//
// Review finding W13 proposed consolidation (either extend ChipState
// with `.onboardingSelected(tone:)` or add `Chip.onboardingVariant`
// init). Rejected after implementation audit: the state spaces model
// different concepts (system-assigned-status vs user-chosen), the
// visual languages are materially different (rounded rect vs capsule,
// labelMd vs labelLg-bold, 32pt vs 44pt min height), and the
// production call sites don't overlap (ScanReview uses Chip; Setup +
// Constraints + Substitution use SelectableChip).
//
// Minimum tap target: 44×44pt. Chips render compact; transparent
// padding fills the gap to HIG floor.
//
// Accessibility: every state pairs color with an icon OR a text cue
// (ink.500 tertiary for likelyStaple). VoiceOver reads the label +
// state suffix ("spinach, confirmed" / "paprika, needs review").

import SwiftUI

enum ChipState: Equatable {
    case normal
    case selected
    case confidenceConfirmed
    case confidenceReview
    case likelyStaple
    case allergenWarning
}

struct Chip: View {
    let title: String
    let state: ChipState
    let action: (() -> Void)?

    init(
        title: String,
        state: ChipState = .normal,
        action: (() -> Void)? = nil,
    ) {
        self.title = title
        self.state = state
        self.action = action
    }

    var body: some View {
        let content = HStack(spacing: CGFloat.Stir.space1 + 2) { // 6pt icon-to-label
            if let iconImage {
                iconImage
                    // justification: 12pt confidence/state icon on the chip — smaller than icon.sm (16pt) so it doesn't dominate the compact chip pill
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .accessibilityHidden(true)
            }
            Text(title)
                .stirFont(.labelMd)
                .foregroundStyle(labelColor)
        }
        .padding(.horizontal, CGFloat.Stir.space3) // 12pt
        .padding(.vertical, CGFloat.Stir.space2)   // 8pt
        .frame(minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusSm, style: .continuous)
                .fill(backgroundColor),
        )
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusSm, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1),
        )
        .contentShape(Rectangle())
        .frame(minWidth: 44, minHeight: 44) // HIG tap-target floor

        if let action {
            Button(action: action) { content }
                .accessibilityLabel(accessibilityLabel)
                .accessibilityAddTraits(.isButton)
        } else {
            content
                .accessibilityLabel(accessibilityLabel)
        }
    }

    // MARK: - State → styling

    private var iconImage: Image? {
        switch state {
        case .normal, .selected, .likelyStaple:
            return nil
        case .confidenceConfirmed:
            return Image.Stir.check
        case .confidenceReview:
            return Image.Stir.help
        case .allergenWarning:
            return Image.Stir.allergen
        }
    }

    private var iconColor: Color {
        switch state {
        case .confidenceConfirmed: return Color.Stir.sage600
        case .confidenceReview:    return Color.Stir.amber600
        case .allergenWarning:     return Color.Stir.crimson600
        default:                   return Color.Stir.ink500
        }
    }

    private var labelColor: Color {
        switch state {
        case .normal, .confidenceConfirmed:
            return Color.Stir.ink700
        case .selected:
            return Color.Stir.ember600
        case .confidenceReview:
            return Color.Stir.amber600
        case .likelyStaple:
            return Color.Stir.ink500
        case .allergenWarning:
            return Color.Stir.crimson600
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .normal, .confidenceConfirmed, .likelyStaple:
            return Color.Stir.paper100
        case .selected:
            return Color.Stir.ember100
        case .confidenceReview:
            return Color.Stir.amber100
        case .allergenWarning:
            return Color.Stir.crimson100
        }
    }

    private var borderColor: Color {
        switch state {
        case .normal, .confidenceConfirmed, .likelyStaple:
            return Color.Stir.divider
        case .selected:
            return Color.Stir.ember600
        case .confidenceReview:
            return Color.Stir.amber600
        case .allergenWarning:
            return Color.Stir.crimson600
        }
    }

    /// VoiceOver — label plus state suffix so a user with a screen
    /// reader hears the confidence semantic without relying on color.
    private var accessibilityLabel: String {
        switch state {
        case .normal:               return title
        case .selected:             return "\(title), selected"
        case .confidenceConfirmed:  return "\(title), confirmed"
        case .confidenceReview:     return "\(title), needs review"
        case .likelyStaple:         return "\(title), likely staple"
        case .allergenWarning:      return "\(title), allergen warning"
        }
    }
}

// MARK: - Previews

#Preview("Chip — light") {
    chipGallery
        .preferredColorScheme(.light)
}

#Preview("Chip — dark") {
    chipGallery
        .preferredColorScheme(.dark)
}

@MainActor
private var chipGallery: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space4) {
            Group {
                label("All six states — stateless")
                HStack(spacing: CGFloat.Stir.space2) {
                    Chip(title: "Spinach")
                    Chip(title: "High protein", state: .selected)
                    Chip(title: "Tomato", state: .confidenceConfirmed)
                }
                HStack(spacing: CGFloat.Stir.space2) {
                    Chip(title: "Paprika", state: .confidenceReview)
                    Chip(title: "Salt", state: .likelyStaple)
                    Chip(title: "Peanut", state: .allergenWarning)
                }

                label("Interactive — tap to toggle in real usage")
                HStack(spacing: CGFloat.Stir.space2) {
                    Chip(title: "Vegetarian", state: .normal, action: {})
                    Chip(title: "Gluten-free", state: .selected, action: {})
                }
            }
            Spacer()
        }
        .padding(CGFloat.Stir.space4)
    }
    .frame(width: 390, height: 844)
    .background(Color.Stir.paper50)
}

@MainActor
private func label(_ text: String) -> some View {
    Text(text)
        .stirFont(.labelEyebrow)
        .foregroundStyle(Color.Stir.textTertiary)
}
