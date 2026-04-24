// DinnerOptionsView
//
// Renders 3 dish cards as they stream in (mockup 05 §Dinner Options).
// Skeleton placeholders before each arrives; progressive fill as the
// SSE events land. Tapping a card pushes DishPreviewView.
//
// Uses Phase 2 DishOptionCard for the populated slot. Slot-specific
// skeleton + error surfaces stay inline — they're one-off during-stream
// states, not reusable components.

import SwiftUI

struct DinnerOptionsView: View {
    @Bindable var viewModel: SolveViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space3 + 2) { // 14pt
                header
                if case .error(let message, let code) = viewModel.phase {
                    errorBanner(message: message, code: code)
                }
                ForEach(viewModel.slots) { slot in
                    slotCard(slot)
                }
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.vertical, CGFloat.Stir.space4)
        }
        .background(Color.Stir.paper50)
        .navigationTitle("Tonight's options")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "solve-once") {
            if viewModel.phase == .constraints {
                viewModel.startSolve()
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
            Text("Three that fit tonight")
                .stirFont(.displayLg)
                .foregroundStyle(Color.Stir.ink900)
                .accessibilityAddTraits(.isHeader)

            if viewModel.phase == .solving {
                Text("Looking at your pantry and constraints…")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
            } else if viewModel.slots.allSatisfy({ $0.dish == nil && $0.errorCode == nil }) {
                Text("Preparing…")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
            }
        }
    }

    @ViewBuilder
    private func slotCard(_ slot: SolveViewModel.SlotState) -> some View {
        if let dish = slot.dish {
            // DishOptionCard no longer wraps its content in a Button —
            // that was double-button-inside-NavigationLink. The
            // NavigationLink provides the tap, DishOptionCardStyle
            // provides the press-feedback. Review finding W-H W33.
            NavigationLink(value: ScanFlowRoot.Route.preview(dish)) {
                DishOptionCard(
                    rank: slot.rank,
                    title: dish.title,
                    totalTimeMinutes: dish.totalTimeMinutes,
                    whyItFits: dish.whyItFits,
                    missingIngredientCount: dish.missingIngredientCount,
                    fitKind: fitLabelKind(
                        for: dish.fitLabelPrimary,
                        missingCount: dish.missingIngredientCount,
                    ),
                )
            }
            .buttonStyle(DishOptionCardStyle())
        } else if slot.errorCode != nil {
            // Error code is intentionally not surfaced in the slot's
            // copy — users don't need the VAL-01 / AI-02 string. The
            // slot keeps the error code on the slot-model itself for
            // Sentry / telemetry; the UI just shows the canned
            // "didn't pass your rules" copy. Review finding W-H W32.
            errorSlot(rank: slot.rank)
        } else {
            skeletonSlot(rank: slot.rank)
        }
    }

    /// Maps the server-side fit-label enum string to Phase 2's
    /// FitLabelKind. `uses_what_you_have` + `new_to_you` don't have
    /// direct visual variants in spec §8.4 — collapse to `.bestFit`
    /// (same voice tint) for now; if a future mockup introduces a
    /// distinct visual variant, extend FitLabelKind.
    private func fitLabelKind(for raw: String, missingCount: Int) -> FitLabelKind {
        // Clamp defensively — a malformed server response with a
        // negative missing-count could render "-2 missing" otherwise.
        // Review finding W-H W36 (CA1).
        let safeCount = max(0, missingCount)
        switch raw {
        case "fastest":       return .fastest
        case "least_waste":   return .leastWaste
        case "best_fit",
             "uses_what_you_have",
             "new_to_you":    return .bestFit
        default:
            return safeCount > 0 ? .missing(count: safeCount) : .bestFit
        }
    }

    private func skeletonSlot(rank: Int) -> some View {
        RoundedRectangle(cornerRadius: CGFloat.Stir.radiusLg, style: .continuous)
            .fill(Color.Stir.paper100)
            .frame(height: 140)
            .overlay(
                RoundedRectangle(cornerRadius: CGFloat.Stir.radiusLg, style: .continuous)
                    .strokeBorder(Color.Stir.divider, lineWidth: 1),
            )
            .overlay(alignment: .topLeading) {
                Text("\(rank)")
                    .stirFont(.displayMd)
                    .foregroundStyle(Color.Stir.ink300)
                    .padding(CGFloat.Stir.space4)
            }
            .overlay(
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Color.Stir.ember600),
            )
            .accessibilityLabel("Option \(rank), loading")
    }

    private func errorBanner(message: String, code: String) -> some View {
        HStack(alignment: .top, spacing: CGFloat.Stir.space3) {
            Image.Stir.softError
                .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                .foregroundStyle(Color.Stir.rust600)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: CGFloat.Stir.space1 + 2) {
                Text(message)
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.ink900)
                Text(code)
                    .stirFont(.monoQuote)
                    .foregroundStyle(Color.Stir.ink500)
                TextButton(title: "Try again") {
                    viewModel.startSolve()
                }
            }
            Spacer()
        }
        .padding(CGFloat.Stir.space3)
        .background(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusCard, style: .continuous)
                .fill(Color.Stir.amber100),
        )
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusCard, style: .continuous)
                .strokeBorder(Color.Stir.amber600.opacity(0.3), lineWidth: 1),
        )
        // NOTE: no `.combine` — the Try again TextButton is an
        // interactive child. Combining would flatten it into the
        // static label and VoiceOver users couldn't retry. Let SwiftUI
        // emit banner text + code + Try again as separate a11y
        // elements. Review finding C3 (FD1).
    }

    private func errorSlot(rank: Int) -> some View {
        HStack(alignment: .top, spacing: CGFloat.Stir.space3) {
            Image.Stir.softError
                .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                .foregroundStyle(Color.Stir.amber600)

            VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
                Text("Option \(rank) didn't pass your rules.")
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.ink900)
                Text("Try loosening one constraint and re-solving.")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
            }
            Spacer()
        }
        .padding(CGFloat.Stir.space3)
        .background(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusCard, style: .continuous)
                .fill(Color.Stir.amber100),
        )
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusCard, style: .continuous)
                .strokeBorder(Color.Stir.amber600.opacity(0.3), lineWidth: 1),
        )
    }
}
