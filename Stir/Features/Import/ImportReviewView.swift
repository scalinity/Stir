// ImportReviewView
//
// Mockup 11 screen 3 — parsed import review + Save CTA. Shows the
// recipe title, servings/time/ingredient/step counts as a metadata
// strip, a collapsible ingredients preview, and a steps preview. The
// "Adapted for your kitchen" diff card from the mockup is deferred
// to a follow-up commit (v1 doesn't run server-side adaptation against
// household rules at import time — that lives in Solve).
//
// Parse quality chip surfaces the backend's self-assessment (high /
// medium / low). Low-quality hints surface to the user so they know
// to double-check before saving.

import SwiftUI

struct ImportReviewView: View {
    @Bindable var viewModel: ImportViewModel
    let recipe: RecipeImportResponse.ImportedRecipe
    let parseQuality: String
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    metadataStrip
                    if parseQuality == "low" {
                        lowQualityNote
                    }
                    ingredientsSection
                    stepsSection
                    Spacer(minLength: 30)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            .background(Color.Stir.paper50.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { footer }
            // Keep `navigationTitle` for the back-chevron label +
            // VoiceOver; the visible title comes from the .principal
            // toolbar item below in the Stir display serif. Default
            // chrome would render in SF Pro Bold and break the
            // cross-screen rhythm (matches Settings / Saved / Pantry).
            .navigationTitle("Review import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelImport()
                        onDismiss()
                    }
                    .foregroundStyle(Color.Stir.ink700)
                }
                ToolbarItem(placement: .principal) {
                    Text("Review import")
                        .stirFont(.displaySm)
                        .foregroundStyle(Color.Stir.textPrimary)
                }
            }
            .toolbarBackground(Color.Stir.paper50, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.Stir.sage600)
                Text("Parsed · \(parseQuality)")
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.sage600)
            }
            Text(recipe.title)
                .stirFont(.displayLg)
                .foregroundStyle(Color.Stir.ink900)
                .lineLimit(3)
        }
    }

    private var metadataStrip: some View {
        HStack(spacing: 14) {
            if let servings = recipe.servings {
                MetaChip(icon: "person.2", label: "\(servings) serves")
            }
            if let minutes = recipe.estimatedMinutes {
                MetaChip(icon: "clock", label: "\(minutes) min")
            }
            MetaChip(icon: "leaf", label: "\(recipe.ingredients.count) ingredients")
            MetaChip(icon: "list.number", label: "\(recipe.steps.count) steps")
            Spacer(minLength: 0)
        }
    }

    private var lowQualityNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14))
                .foregroundStyle(Color.Stir.rust600)
            Text("Parse confidence is low. Double-check the ingredients before saving.")
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink700)
            Spacer(minLength: 0)
        }
        .padding(CGFloat.Stir.space3Half)
        .stirCard(
            borderColor: Color.Stir.rust600.opacity(0.4),
            radius: CGFloat.Stir.radiusMd,
        )
    }

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ingredients")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.ink500)
            VStack(spacing: 0) {
                ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { idx, ing in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ing.displayName)
                            .stirFont(.bodyMd)
                            .foregroundStyle(Color.Stir.ink900)
                        Spacer(minLength: 8)
                        if let amount = ing.amountText, !amount.isEmpty {
                            Text(amount)
                                .stirFont(.bodySm)
                                .foregroundStyle(Color.Stir.ink500)
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .overlay(alignment: .bottom) {
                        if idx < recipe.ingredients.count - 1 {
                            Rectangle()
                                .fill(Color.Stir.ink100)
                                .frame(height: 1)
                                .padding(.leading, 12)
                        }
                    }
                }
            }
            .stirCard(borderColor: nil, radius: CGFloat.Stir.radiusMd)
        }
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Steps")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.ink500)
            VStack(spacing: 8) {
                ForEach(recipe.steps, id: \.stepNumber) { step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(step.stepNumber)")
                            .stirFont(.bodySm)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.Stir.ember600)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.Stir.ember100))
                        Text(step.instructionText)
                            .stirFont(.bodyMd)
                            .foregroundStyle(Color.Stir.ink900)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.Stir.paper100),
                    )
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        Button {
            Task { await viewModel.confirmAndSave() }
        } label: {
            HStack(spacing: 8) {
                if viewModel.isBusy {
                    ProgressView().tint(.white)
                }
                Text(viewModel.isBusy ? "Saving…" : "Save to Saved")
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(viewModel.isBusy ? Color.Stir.ink300 : Color.Stir.ember600),
            )
        }
        .disabled(viewModel.isBusy)
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .background(Color.Stir.paper50.ignoresSafeArea(.all, edges: .bottom))
    }
}

// MARK: - Meta chip

private struct MetaChip: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Color.Stir.ink500)
            Text(label)
                .stirFont(.bodySm)
                .fontWeight(.medium)
                .foregroundStyle(Color.Stir.ink700)
        }
    }
}
