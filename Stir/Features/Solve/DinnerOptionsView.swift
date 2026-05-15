// DinnerOptionsView
//
// Renders 3 dish cards as they stream in (mockup 05 §Dinner Options).
// Skeleton placeholders before each arrives; progressive fill as the
// SSE events land. Tapping a card pushes DishPreviewView. The trailing
// "Tune" toolbar button re-presents the constraints sheet so the user
// can adjust their constraints and re-solve in place.
//
// Uses Phase 2 DishOptionCard for the populated slot. Slot-specific
// skeleton + error surfaces stay inline — they're one-off during-stream
// states, not reusable components.

import SwiftUI

struct DinnerOptionsView: View {
    @Bindable var viewModel: SolveViewModel
    /// Re-presents the constraints sheet from the parent NavigationStack
    /// so a user already standing on the options screen can adjust their
    /// constraints and re-solve in place. ScanFlowRoot owns the sheet
    /// presentation state; we just signal it.
    let onTune: () -> Void


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
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
        // Keep `navigationTitle` for the back-chevron label +
        // VoiceOver; the visible title comes from the .principal
        // toolbar item below in the Stir display serif. Default
        // chrome would render in SF Pro Bold and break the
        // cross-screen rhythm (matches Settings / Saved / Pantry).
        .navigationTitle("Dinner options")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Dinner options")
                    .stirFont(.displaySm)
                    .foregroundStyle(Color.Stir.textPrimary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                // `.buttonStyle(.plain)` — see SolveAgainRoot's Cancel
                // for the iOS 26 Liquid Glass suppression rationale.
                Button("Tune", action: onTune)
                    .buttonStyle(.plain)
                    .stirFont(.bodyMd)
                    .foregroundStyle(Color.Stir.ember600)
            }
        }
        .toolbarBackground(Color.Stir.paper50, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task(id: "solve-once") {
            if viewModel.phase == .constraints {
                viewModel.startSolve()
            }
        }
        // SCA-19 — full-screen dinner-options tutorial. Suppressed
        // until at least one slot has resolved a dish so the cover
        // doesn't slide up over a screen full of skeletons.
        .tutorial(
            key: .dinnerOptions,
            content: { DinnerOptionsTutorial() },
            shouldPresent: viewModel.slots.contains { $0.dish != nil },
        )
    }

    // MARK: - Sections

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
                    tonightPick: slot.rank == 1,
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

    private func skeletonSlot(rank: Int) -> some View {
        // Mirrors DishOptionCard's horizontal plate-on-left silhouette
        // so the loading-→-loaded transition lands without a layout
        // jump. Fixed minHeight keeps the skeleton tall enough to read
        // as a card placeholder rather than a thin row.
        HStack(spacing: 0) {
            ZStack {
                Color.Stir.paper200
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Color.Stir.ember600)
            }
            .frame(width: 104)
            .frame(maxHeight: .infinity)

            Text("Option \(rank)")
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.ink300)
                .padding(.horizontal, CGFloat.Stir.space4)
                .padding(.vertical, CGFloat.Stir.space3Half)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(minHeight: 116)
        .stirCard(radius: CGFloat.Stir.radiusLg)
        .clipShape(RoundedRectangle(cornerRadius: CGFloat.Stir.radiusLg, style: .continuous))
        // Collapse the inline "Option N" text + ProgressView into one
        // VoiceOver element matching the loaded-card pattern; without
        // `.ignore` VoiceOver double-reads the rank ("Option 1,
        // Option 1, loading").
        .accessibilityElement(children: .ignore)
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
        .stirCard(
            fill: Color.Stir.amber100,
            borderColor: Color.Stir.amber600.opacity(0.3),
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
        .stirCard(
            fill: Color.Stir.amber100,
            borderColor: Color.Stir.amber600.opacity(0.3),
        )
    }
}
