// Chip
//
// Small selectable pill used extensively on Scan Review (ingredient
// chips with confidence signals) and Setup onboarding (preference
// chips). Spec §8.2 defines six visual states; this component models
// them via a ChipState enum.
//
// States:
//   - `.default`             → paper.100 fill, ink.700 label, ink.100
//                              border (unselected resting)
//   - `.selected`            → ember.100 fill, ember.600 label+border
//                              (user toggled on — Setup preferences)
//   - `.confidenceConfirmed` → default + sage.600 checkmark
//   - `.confidenceReview`    → amber.100 fill, amber.600 label, amber
//                              questionmark (AI flagged for review)
//   - `.likelyStaple`        → default + ink.500 text (lowest emphasis
//                              — the model is fairly sure but the user
//                              should confirm staples like salt)
//   - `.allergenWarning`     → crimson.100 fill, crimson.600 label,
//                              crimson allergen triangle (hard rule)
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
