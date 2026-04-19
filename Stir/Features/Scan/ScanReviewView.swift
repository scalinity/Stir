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
            VStack(alignment: .leading, spacing: 20) {
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
            .padding()
        }
        .navigationTitle("Review ingredients")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if case .review = viewModel.phase {
                confirmBar
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .background(.bar)
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

        return VStack(alignment: .leading, spacing: 6) {
            Text("\(count) ingredients spotted")
                .font(.headline)
            if needsReview > 0 {
                Text("\(needsReview) need a quick confirm before we solve.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Tap a chip to tweak, long-press to delete.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chipsGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(viewModel.ingredients) { ingredient in
                chip(for: ingredient)
            }
        }
    }

    private func chip(for ingredient: ScanViewModel.Ingredient) -> some View {
        let palette = palette(for: ingredient.confidence)
        return Button {
            editTarget = ingredient
            editBuffer = ingredient.displayName
        } label: {
            HStack(spacing: 6) {
                palette.icon
                Text(ingredient.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(palette.bg, in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(palette.fg)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                viewModel.deleteIngredient(id: ingredient.id)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .accessibilityLabel("\(ingredient.displayName), \(ingredient.confidence.accessibilityDescription)")
        .accessibilityHint("Double-tap to edit, long-press for more options.")
    }

    private var addButton: some View {
        Button {
            addBuffer = ""
            showAddAlert = true
        } label: {
            Label("Add an ingredient", systemImage: "plus.circle")
                .font(.subheadline.weight(.medium))
        }
        .padding(.top, 4)
    }

    private var confirmBar: some View {
        Button {
            onConfirm()
        } label: {
            Text("Looks right — find dinners")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
        }
        .disabled(viewModel.ingredients.isEmpty)
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgressView("Looking at your kitchen…")
                .progressViewStyle(.circular)
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 80, height: 32)
                }
            }
        }
    }

    private func errorCard(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Helpers

    private struct Palette {
        var bg: Color
        var fg: Color
        var icon: AnyView
    }

    private func palette(for confidence: PantryParseResponse.PantryItemConfidence) -> Palette {
        switch confidence {
        case .confirmed:
            return Palette(
                bg: Color(.tertiarySystemBackground),
                fg: .primary,
                icon: AnyView(Image(systemName: "checkmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)),
            )
        case .needsReview:
            return Palette(
                bg: Color.yellow.opacity(0.2),
                fg: .primary,
                icon: AnyView(Image(systemName: "questionmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)),
            )
        case .likelyStaple:
            return Palette(
                bg: Color(.secondarySystemBackground),
                fg: .secondary,
                icon: AnyView(Image(systemName: "sparkles")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)),
            )
        }
    }

    private func bindingIsPresented(forEdit: Bool) -> Binding<Bool> {
        Binding(
            get: { editTarget != nil },
            set: { newValue in if !newValue { editTarget = nil } },
        )
    }
}

private extension PantryParseResponse.PantryItemConfidence {
    var accessibilityDescription: String {
        switch self {
        case .confirmed:    return "confirmed"
        case .needsReview:  return "needs review"
        case .likelyStaple: return "likely staple"
        }
    }
}
