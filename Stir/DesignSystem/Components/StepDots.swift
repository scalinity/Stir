// StepDots
//
// Page-dot progress indicator: an active capsule (wider) with N-1 inactive
// dots. Mirrors the Cook Mode mockup eyebrow column
// (`stir-app-design/project/DesignMockups/06_cook_mode_tap.html:60-63`):
//
//     [• • • ━━ • •]   ← step 4 of 6 (active dot widens into a capsule)
//
// Sizing follows the mockup: 5×5 inactive, 18×5 active. Spacing 4pt to
// match the row's letter-spacing density. Distinct from
// `TutorialFlowContainer.progressDots` (8pt-tall, 20pt active) — these
// dots are smaller because they sit under a 10pt eyebrow inside Cook
// Mode's compact top chrome rather than as the dominant page indicator.
//
// Accessibility: collapses into a single combined element reading
// "Step N of M" — VoiceOver users don't need M individual dot
// announcements.

import SwiftUI

struct StepDots: View {
    /// 1-indexed current step (matches the mockup's `step={3}` prop).
    let step: Int

    /// Total number of steps in the recipe.
    let total: Int

    /// Color for completed / active dots. Defaults to ember600 to match
    /// the Cook Mode "Now" eyebrow accent.
    let activeColor: Color

    /// Color for upcoming dots. Defaults to ink100 for low-contrast rest.
    let inactiveColor: Color

    init(
        step: Int,
        total: Int,
        activeColor: Color = Color.Stir.ember600,
        inactiveColor: Color = Color.Stir.ink100,
    ) {
        self.step = step
        self.total = total
        self.activeColor = activeColor
        self.inactiveColor = inactiveColor
    }

    var body: some View {
        HStack(spacing: 4) {
            // Single 5pt height keeps the row visually quiet under a
            // tracked-uppercase eyebrow — anything taller competes
            // with the eyebrow text for attention.
            ForEach(0 ..< max(total, 0), id: \.self) { idx in
                Capsule()
                    .fill(idx < step ? activeColor : inactiveColor)
                    // Active dot widens into an 18pt capsule
                    // (mockup `width: i===step-1 ? 18 : 5`). Width
                    // anchors on `idx == step - 1` so completed dots
                    // (idx < step - 1) stay 5pt round.
                    .frame(width: idx == step - 1 ? 18 : 5, height: 5)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step) of \(total)")
    }
}

#if DEBUG
#Preview("StepDots") {
    VStack(spacing: 16) {
        StepDots(step: 1, total: 5)
        StepDots(step: 3, total: 5)
        StepDots(step: 5, total: 5)
    }
    .padding()
    .background(Color.Stir.paper50)
}
#endif
