// DinnerOptionsView
//
// Renders 3 dish cards as they stream in (mockup 05 §Dinner Options).
// Skeleton placeholders before each arrives; progressive fill as the
// SSE events land. Tapping a card pushes DishPreviewView. The trailing
// "Tune" header button re-presents the constraints sheet so the user
// can adjust their constraints and re-solve in place.
//
// Uses Phase 2 DishOptionCard for the populated slot. Slot-specific
// skeleton + error surfaces stay inline — they're one-off during-stream
// states, not reusable components.
//
// Custom `.safeAreaInset(.top)` header replaces the system toolbar
// (SCA-456). iOS 26 paints toolbar Buttons with Liquid Glass material
// — capsules + circles that read as off-theme against the warm-paper
// Stir surface and squeeze the principal serif title. Dropping the
// toolbar entirely is the only reliable opt-out, matching SCA-436's
// DishPreview pattern. `onCancel` is optional: SolveAgainRoot passes
// a dismiss closure (cover-level exit since back-nav leads to a hidden
// placeholder), ScanFlowRoot passes nil and the leading slot renders
// a Stir back-chevron that calls `dismiss()` to pop to .review.

import SwiftUI

struct DinnerOptionsView: View {
    @Bindable var viewModel: SolveViewModel
    /// Re-presents the constraints sheet from the parent NavigationStack
    /// so a user already standing on the options screen can adjust their
    /// constraints and re-solve in place. ScanFlowRoot owns the sheet
    /// presentation state; we just signal it.
    let onTune: () -> Void
    /// When non-nil, the leading header slot renders a "Cancel" text
    /// button that invokes this closure. SolveAgainRoot passes
    /// `onDismiss` (drops the cover); ScanFlowRoot passes nil so the
    /// leading slot renders a back-chevron StirCircleIconButton that
    /// calls `dismiss()` to pop to .review.
    let onCancel: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    init(
        viewModel: SolveViewModel,
        onTune: @escaping () -> Void,
        onCancel: (() -> Void)? = nil,
    ) {
        self._viewModel = Bindable(viewModel)
        self.onTune = onTune
        self.onCancel = onCancel
    }

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
        // Keep `navigationTitle` for VoiceOver and for any caller that
        // pushes a deeper screen on top of this one (the implicit back-
        // chevron label reads from here). The visible chrome is the
        // custom `.safeAreaInset(.top)` header below — the system
        // toolbar route paints iOS 26 Liquid Glass on every Button
        // inside it, and there's no per-button opt-out.
        .navigationTitle("Dinner options")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            stirTopBar
        }
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

    // MARK: - Custom top bar (SCA-456)

    /// `.safeAreaInset(.top)` replacement for the system toolbar.
    /// Leading slot = Cancel text (cover entry) or back-chevron round-
    /// icon (scan-flow entry). Center = full-width serif title. Trailing
    /// = Tune text button. All buttons render outside the system
    /// toolbar so iOS 26's automatic Liquid Glass material is bypassed.
    private var stirTopBar: some View {
        HStack(alignment: .center, spacing: CGFloat.Stir.space2) {
            leadingControl
            Text("Dinner options")
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityAddTraits(.isHeader)
            trailingControl
        }
        .padding(.horizontal, CGFloat.Stir.space3)
        .padding(.vertical, CGFloat.Stir.space2)
        .background(Color.Stir.paper50)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.Stir.divider)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var leadingControl: some View {
        if let onCancel {
            Button("Cancel", action: onCancel)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ember600)
                .frame(minHeight: 44)
                .frame(width: 88, alignment: .leading)
        } else {
            StirCircleIconButton(
                icon: Image(systemName: "chevron.left"),
                accessibilityLabel: "Back",
                action: { dismiss() },
            )
            .frame(width: 88, alignment: .leading)
        }
    }

    private var trailingControl: some View {
        Button("Tune", action: onTune)
            .stirFont(.bodyMd)
            .foregroundStyle(Color.Stir.ember600)
            .frame(minHeight: 44)
            .frame(width: 88, alignment: .trailing)
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
