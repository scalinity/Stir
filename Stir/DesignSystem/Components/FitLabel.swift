// FitLabel
//
// Small pill on DishOptionCard expressing why a suggestion fits
// (Specs/Design-System.md §8.4). One label per card — the primary fit
// reason; secondary reasons go in the "why it fits" body copy, not as
// second badges.
//
// Four exhaustive variants:
//   - `.fastest`        → ember.100 bg / ember.600 text
//   - `.leastWaste`     → sage.100 bg / sage.600 text
//   - `.bestFit`        → voice.100 bg / voice.600 text
//                          (reuses the voice palette sparingly here —
//                          §8.4 explicit)
//   - `.missing(count)` → paper.200 bg / ink.700 text
//
// Radius is .full (pill), padding is compact. Text uses label.md medium
// — small but never smaller than 13pt so it stays legible on card.

import SwiftUI

enum FitLabelKind: Equatable {
    case fastest
    case leastWaste
    case bestFit
    case missing(count: Int)
}

struct FitLabel: View {
    let kind: FitLabelKind

    var body: some View {
        Text(displayText)
            .stirFont(.labelMd)
            .foregroundStyle(foreground)
            .padding(.horizontal, CGFloat.Stir.space3 - 2) // 10pt — tight pill
            .padding(.vertical, CGFloat.Stir.space1 + 2)   // 6pt
            .background(
                Capsule(style: .continuous)
                    .fill(background),
            )
            .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Variant → styling

    private var displayText: String {
        switch kind {
        case .fastest:             return "Fastest"
        case .leastWaste:          return "Least waste"
        case .bestFit:             return "Best fit"
        case .missing(let count):
            return count == 1 ? "Missing 1" : "Missing \(count)"
        }
    }

    private var foreground: Color {
        switch kind {
        case .fastest:     return Color.Stir.ember600
        case .leastWaste:  return Color.Stir.sage600
        case .bestFit:     return Color.Stir.voice600
        case .missing:     return Color.Stir.ink700
        }
    }

    private var background: Color {
        switch kind {
        case .fastest:     return Color.Stir.ember100
        case .leastWaste:  return Color.Stir.sage100
        case .bestFit:     return Color.Stir.voice100
        case .missing:     return Color.Stir.paper200
        }
    }

    /// VoiceOver reads the fit reason in plain language so users aren't
    /// left to infer meaning from a color-differentiated pill.
    private var accessibilityLabel: String {
        switch kind {
        case .fastest:             return "Fit reason: fastest to cook"
        case .leastWaste:          return "Fit reason: least food waste"
        case .bestFit:             return "Fit reason: best overall match"
        case .missing(let count):
            return count == 1
                ? "Missing 1 ingredient"
                : "Missing \(count) ingredients"
        }
    }
}

// MARK: - Previews

#Preview("FitLabel — light") {
    fitLabelGallery
        .preferredColorScheme(.light)
}

#Preview("FitLabel — dark") {
    fitLabelGallery
        .preferredColorScheme(.dark)
}

@MainActor
private var fitLabelGallery: some View {
    VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
        Text("All four variants")
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.textTertiary)
        FitLabel(kind: .fastest)
        FitLabel(kind: .leastWaste)
        FitLabel(kind: .bestFit)
        FitLabel(kind: .missing(count: 1))
        FitLabel(kind: .missing(count: 3))
        Spacer()
    }
    .padding(CGFloat.Stir.space4)
    .frame(width: 390, height: 844)
    .background(Color.Stir.paper50)
}
