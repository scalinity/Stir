// ScanReviewView
//
// Parsed-ingredient review screen. Chips render with confidence-band
// styling (confirmed neutral, needs_review amber, likely_staple secondary)
// per spec §6. Each chip can be edited (tap) or deleted (swipe/hold),
// and users can add missing items manually.
//
// "Looks right" CTA commits the reviewed list to PantryItem and advances
// to the constraints + solve flow.

import SwiftUI

struct ScanReviewView: View {
    @Bindable var viewModel: ScanViewModel
    let onConfirm: () -> Void

    @State private var editTarget: ScanViewModel.Ingredient?
    @State private var editBuffer: String = ""
    @State private var showAddAlert: Bool = false
    @State private var addBuffer: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                if case .parsing = viewModel.phase {
                    skeleton
                } else if case .error(let message, _) = viewModel.phase {
                    errorCard(message: message)
                } else {
                    summaryBanner
                    chipsGrid
                    addButton
                }
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.vertical, CGFloat.Stir.space4)
        }
        .background(Color.Stir.paper50)
        .navigationTitle("Review ingredients")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            // Show the confirm bar whenever the user is on this
            // screen with ingredients available — that includes
            // `.review` (first visit) AND `.confirmed` (user went
            // forward, then tapped back to edit). The bar is hidden
            // only during `.parsing` (skeleton has its own layout)
            // and `.error` (error card owns the screen).
            switch viewModel.phase {
            case .review, .confirmed:
                confirmBar
                    .padding(.horizontal, CGFloat.Stir.screenMargin)
                    .padding(.vertical, CGFloat.Stir.space3)
                    .background(.bar)
            default:
                EmptyView()
            }
        }
        .alert("Edit ingredient", isPresented: bindingIsPresented(forEdit: true)) {
            TextField("Ingredient name", text: $editBuffer)
            Button("Save") {
                if let target = editTarget {
                    viewModel.editIngredient(id: target.id, newName: editBuffer)
                }
                editTarget = nil
                editBuffer = ""
            }
            Button("Cancel", role: .cancel) {
                editTarget = nil
                editBuffer = ""
            }
        }
        .alert("Add ingredient", isPresented: $showAddAlert) {
            TextField("Ingredient name", text: $addBuffer)
            Button("Add") {
                viewModel.addIngredientManually(addBuffer)
                addBuffer = ""
            }
            Button("Cancel", role: .cancel) {
                addBuffer = ""
            }
        }
    }

    // MARK: - Sections

    private var summaryBanner: some View {
        let count = viewModel.ingredients.count
        let needsReview = viewModel.ingredients.filter { $0.confidence == .needsReview }.count

        return VStack(alignment: .leading, spacing: CGFloat.Stir.space1 + 2) { // 6pt
            HStack(alignment: .firstTextBaseline, spacing: CGFloat.Stir.space2) {
                Text("Found \(count) things")
                    .stirFont(.displayLg)
                    .foregroundStyle(Color.Stir.ink900)
                    .accessibilityAddTraits(.isHeader)

                HStack(spacing: CGFloat.Stir.space1) {
                    Image.Stir.sparkles
                        .font(.system(size: 12, weight: .semibold)) // justification: 12pt AI micro-tag per mockup 04 chip-scale adornment
                    Text("AI")
                        .stirFont(.labelEyebrow)
                }
                .foregroundStyle(Color.Stir.sage600)
            }

            Text(needsReview > 0
                 ? "\(needsReview) need a quick confirm before we solve."
                 : "Tap a chip to tweak, long-press to delete.")
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink500)
        }
    }

    private var chipsGrid: some View {
        // Uses Phase 2 Chip component — confidence-band state maps
        // directly to ChipState variants (confirmed→.confidenceConfirmed,
        // needsReview→.confidenceReview, likelyStaple→.likelyStaple).
        // Grouping by protein/produce/pantry per mockup 04 §Review is
        // deferred: ScanViewModel.Ingredient has no category metadata,
        // and Pantry Parse response doesn't emit a category field yet.
        // Flat chip grid preserves current behavior + visual drift only
        // in group structure, not chip styling.
        let columns = [GridItem(.adaptive(minimum: 110), spacing: CGFloat.Stir.space2)]
        return LazyVGrid(columns: columns, spacing: CGFloat.Stir.space2) {
            ForEach(viewModel.ingredients) { ingredient in
                Chip(
                    title: ingredient.displayName,
                    state: chipState(for: ingredient.confidence),
                    action: {
                        editTarget = ingredient
                        editBuffer = ingredient.displayName
                    },
                )
                .contextMenu {
                    Button(role: .destructive) {
                        viewModel.deleteIngredient(id: ingredient.id)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func chipState(for confidence: PantryParseResponse.PantryItemConfidence) -> ChipState {
        switch confidence {
        case .confirmed:    return .confidenceConfirmed
        case .needsReview:  return .confidenceReview
        case .likelyStaple: return .likelyStaple
        }
    }

    private var addButton: some View {
        Button {
            addBuffer = ""
            showAddAlert = true
        } label: {
            HStack(spacing: CGFloat.Stir.space1 + 2) { // 6pt
                Image.Stir.plus
                    .font(.system(size: 12, weight: .semibold)) // justification: inline-plus sized to match Chip pill scale
                Text("Add an ingredient")
                    .stirFont(.labelMd)
            }
            .foregroundStyle(Color.Stir.ink500)
            .padding(.horizontal, CGFloat.Stir.space3)
            .padding(.vertical, CGFloat.Stir.space2)
            .frame(minHeight: 44)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        Color.Stir.ink300,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3]),
                    ),
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, CGFloat.Stir.space1)
    }

    private var confirmBar: some View {
        PrimaryButton(
            title: "Find me dinner",
            isDisabled: viewModel.ingredients.isEmpty,
            action: onConfirm,
        )
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space4) {
            HStack(spacing: CGFloat.Stir.space2) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Color.Stir.ember600)
                Text("Looking at your kitchen…")
                    .stirFont(.labelLg)
                    .foregroundStyle(Color.Stir.ink700)
            }
            HStack(spacing: CGFloat.Stir.space2) {
                ForEach(0 ..< 3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: CGFloat.Stir.radiusSm, style: .continuous)
                        .fill(Color.Stir.paper200)
                        .frame(width: 80, height: 32)
                }
            }
        }
    }

    private func errorCard(message: String) -> some View {
        VStack(spacing: CGFloat.Stir.space3 - 2) { // 10pt
            Image.Stir.softError
                .font(.system(size: CGFloat.Stir.iconLg, weight: .regular))
                .foregroundStyle(Color.Stir.rust600)
            Text(message)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink700)
                .multilineTextAlignment(.center)
        }
        .padding(CGFloat.Stir.space4)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusCard, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusCard, style: .continuous)
                .strokeBorder(Color.Stir.divider, lineWidth: 1),
        )
    }

    // MARK: - Helpers

    private func bindingIsPresented(forEdit: Bool) -> Binding<Bool> {
        Binding(
            get: { editTarget != nil },
            set: { newValue in if !newValue { editTarget = nil } },
        )
    }
}
