// SectionEyebrow
//
// Small uppercase eyebrow above grouped-list / form sections
// (Settings, Notifications, Household preferences, OutcomeFeedback).
// Lifted from four feature-local copies (SCA-95) so a future tweak
// to the eyebrow's font / colour / spacing hits one site instead of
// four-plus drifting forks.
//
// Two tones map to the two variants observed in production:
//
//   - `.standard` — `textTertiary` ink + `space1` horizontal pad.
//                   Used by `SettingsRootView`, `HouseholdPreferencesView`,
//                   `NotificationPrefsView`, `TutorialReplayView`. The
//                   horizontal pad nudges the eyebrow inboard so it visually
//                   aligns with the body text inside the adjacent
//                   `.stirCard()`, not the card edge.
//
//   - `.compact`  — `ink500` ink, no horizontal pad. Used by
//                   `OutcomeFeedbackView`'s chip sections, where the
//                   eyebrow sits flush with full-bleed content rows.
//
// Accessibility: inherits the underlying `Text` semantics — VoiceOver reads
// the eyebrow ahead of the section content, matching the visual ordering.

import SwiftUI

struct SectionEyebrow: View {
    enum Tone {
        /// Settings-style: `textTertiary` ink, `space1` horizontal pad.
        case standard
        /// OutcomeFeedback-style: `ink500` ink, no horizontal pad.
        case compact
    }

    let text: String
    let tone: Tone

    init(_ text: String, tone: Tone = .standard) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .stirFont(.labelEyebrow)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPad)
    }

    private var foreground: Color {
        switch tone {
        case .standard: return Color.Stir.textTertiary
        case .compact: return Color.Stir.ink500
        }
    }

    private var horizontalPad: CGFloat {
        switch tone {
        case .standard: return CGFloat.Stir.space1
        case .compact: return 0
        }
    }
}

#if DEBUG
#Preview("SectionEyebrow") {
    VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
        SectionEyebrow("Plan & Billing")
        SectionEyebrow("Your rating", tone: .compact)
    }
    .padding()
    .background(Color.Stir.paper50)
}
#endif
