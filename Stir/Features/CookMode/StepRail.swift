// StepRail
//
// Cook Mode tap-mode progress rail. Replaces the page-dot indicator
// (`StepDots`) inside the top bar with a horizontal-scroll strip of
// numbered chips that show completed / current / upcoming state and
// route taps through `viewModel.jumpToStep(_:advancedBy:)`.
//
// Shipped under SCA-433 as part of the empty-middle redesign — dots
// gave progress signal but no journey context; the rail keeps the
// at-a-glance progress read AND lets the user peek at what's coming
// (and jump back to a step they want to re-check). Each chip is
// 36pt circle + optional 60pt label column, matching the close-button
// grammar in the top bar.
//
// State legend per chip:
//   - Completed:  ember100 circle, ember600 check, ink500 label.
//   - Current:    ember600 circle, paper50 number, ember600 label.
//   - Upcoming:   paper100 circle with paper200 stroke, ink500 number
//                 and label.
//
// Auto-scrolls the active chip into view on step change. Tap → jump.
// VoiceOver: each chip is its own element with a value-shaped a11y
// announcement ("Step 3 of 5, current") so users hear position
// without re-reading the whole row.

import SwiftUI

struct StepRail: View {
    /// 0-indexed current step. Matches `CookModeViewModel.currentStepIndex`.
    let currentIndex: Int

    /// Total number of steps. Display gracefully degrades to a single
    /// chip when total == 1; renders nothing when total == 0.
    let totalSteps: Int

    /// Optional per-step short title used as the small label under the
    /// chip. Indexed 0..<totalSteps. Indices outside the bounds — or
    /// nil entries — render no label. Title strings longer than ~10
    /// chars are truncated with tail ellipsis so the rail stays a
    /// single row visually.
    let stepTitles: [String?]

    /// Tap handler — caller routes to `viewModel.jumpToStep`. Receives
    /// the 0-indexed destination so the caller doesn't have to undo a
    /// 1-indexed conversion.
    let onJump: (Int) -> Void

    // SCA-448 (S7): `@ViewBuilder` lets the `if` fall through cleanly
    // without an explicit `EmptyView()` arm — SwiftUI handles the
    // "no view in this branch" shape implicitly.
    @ViewBuilder
    var body: some View {
        if totalSteps > 0 {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: CGFloat.Stir.space3) {
                        ForEach(0 ..< totalSteps, id: \.self) { idx in
                            chip(for: idx)
                                .id(idx)
                                .onTapGesture {
                                    if idx != currentIndex {
                                        onJump(idx)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, CGFloat.Stir.space4)
                }
                .onChange(of: currentIndex) { _, new in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
                .onAppear {
                    proxy.scrollTo(currentIndex, anchor: .center)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func chip(for idx: Int) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(circleFill(for: idx))
                    .frame(width: 36, height: 36)
                Circle()
                    .strokeBorder(circleStroke(for: idx), lineWidth: 1)
                    .frame(width: 36, height: 36)

                if idx < currentIndex {
                    // Completed — check glyph.
                    Image(systemName: "checkmark")
                        .stirFont(.labelMd).fontWeight(.semibold)
                        .foregroundStyle(Color.Stir.ember600)
                } else {
                    Text("\(idx + 1)")
                        .stirFont(.labelMd).fontWeight(.semibold)
                        .foregroundStyle(numberColor(for: idx))
                }
            }

            if let raw = label(for: idx) {
                Text(raw)
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(labelColor(for: idx))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 60)
            } else {
                // Reserve baseline space so chips without labels align
                // vertically with chips that have them. Keeps the rail
                // from jittering visually when a recipe mixes titled
                // and untitled steps.
                Text(" ")
                    .stirFont(.labelEyebrow)
                    .opacity(0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(idx + 1) of \(totalSteps)")
        .accessibilityValue(a11yState(for: idx))
        .accessibilityAddTraits(idx == currentIndex ? .isSelected : [])
    }

    private func label(for idx: Int) -> String? {
        guard idx >= 0, idx < stepTitles.count else { return nil }
        guard let raw = stepTitles[idx]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw
    }

    private func circleFill(for idx: Int) -> Color {
        if idx < currentIndex { return Color.Stir.ember100 }
        if idx == currentIndex { return Color.Stir.ember600 }
        return Color.Stir.paper100
    }

    private func circleStroke(for idx: Int) -> Color {
        if idx < currentIndex { return Color.Stir.ember600.opacity(0.4) }
        if idx == currentIndex { return Color.Stir.ember600 }
        return Color.Stir.paper200
    }

    private func numberColor(for idx: Int) -> Color {
        if idx == currentIndex { return Color.Stir.paper50 }
        return Color.Stir.ink500
    }

    private func labelColor(for idx: Int) -> Color {
        if idx == currentIndex { return Color.Stir.ember600 }
        return Color.Stir.ink500
    }

    private func a11yState(for idx: Int) -> String {
        if idx < currentIndex { return "completed" }
        if idx == currentIndex { return "current" }
        return "upcoming"
    }
}

#if DEBUG
#Preview("StepRail") {
    VStack(alignment: .leading, spacing: 24) {
        StepRail(
            currentIndex: 0,
            totalSteps: 5,
            stepTitles: ["Preheat", "Season", "Grill", "Rest", "Plate"],
            onJump: { _ in },
        )
        StepRail(
            currentIndex: 2,
            totalSteps: 5,
            stepTitles: ["Preheat", "Season", "Grill", "Rest", "Plate"],
            onJump: { _ in },
        )
        StepRail(
            currentIndex: 4,
            totalSteps: 5,
            stepTitles: ["Preheat", "Season", "Grill", "Rest", "Plate"],
            onJump: { _ in },
        )
        StepRail(
            currentIndex: 3,
            totalSteps: 9,
            stepTitles: Array(repeating: nil, count: 9),
            onJump: { _ in },
        )
    }
    .padding(.vertical, 12)
    .background(Color.Stir.paper50)
}
#endif
