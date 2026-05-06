// ScanReviewView
//
// Parsed-ingredient review screen, mockup-04 layout. Two buckets:
//   - CONFIRMED merges `.confirmed` + `.likelyStaple`. Staple chips
//     keep their lower-emphasis ink500 text inside the same paper200
//     capsule so the spec §8.2 confidence semantic survives the
//     visual collapse.
//   - NEEDS REVIEW renders `.needsReview` chips with a dashed amber
//     border to flag uncertain ingredients.
//
// First N confirmed chips render inline; the rest fold behind a
// "+ X more" overflow chip. Tapping the overflow chip expands the
// section to show all confirmed items.
//
// Tap a chip to edit. Long-press / context menu to remove. A
// dashed-ink "+ Add" chip (placed at the tail of whichever bucket is
// last) opens an alert for adding missing items.
//
// Implementation notes:
//   - The user-supplied target image displays a different total than
//     its own per-section sums (42 ≠ 28 + 3). The image numbers are
//     illustrative; this view computes counts from the live VM, so
//     header total + section totals stay consistent at runtime.
//   - The nav bar stays present (with an empty title) instead of
//     `.toolbar(.hidden)`. The system back chevron is the only
//     discoverable retake affordance and the cost of hiding it
//     (HIG / VoiceOver focus order) outweighs strict image fidelity.

import SwiftUI

struct ScanReviewView: View {
    @Bindable var viewModel: ScanViewModel
    let onConfirm: () -> Void

    @State private var editTarget: ScanViewModel.Ingredient?
    @State private var editBuffer: String = ""
    @State private var showAddAlert: Bool = false
    @State private var addBuffer: String = ""
    @State private var confirmedExpanded: Bool = false

    /// Coach-mark controller injected by the presenter modifier. Used
    /// to advance the action-gated Solve step.

    /// First N confirmed chips render inline; the rest fold behind a
    /// "+ X more" overflow chip until the user expands the section.
    /// 9 keeps the section roughly three rows on iPhone 15 Pro.
    private static let confirmedVisibleLimit = 9

    /// 10pt vertical padding shared across every chip variant. Keeps
    /// the row pitch identical so confirmed / needs-review / overflow
    /// / add chips line-flow without baseline drift.
    private static let chipVerticalPadding: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch viewModel.phase {
            case .parsing:
                skeleton
                    .padding(.horizontal, CGFloat.Stir.screenMargin)
                    .padding(.top, CGFloat.Stir.space5)
                Spacer()
            case let .error(message, _):
                errorCard(message: message)
                    .padding(CGFloat.Stir.screenMargin)
                Spacer()
            default:
                ScrollView {
                    // CA3-H1 fix: compute buckets ONCE per body eval and
                    // pass to both sections. Prior code re-partitioned
                    // viewModel.ingredients on every read of `buckets`,
                    // and `confirmedSection` read it twice (`buckets.confirmed`
                    // + `buckets.needsReview.count`) plus `needsReviewSection`
                    // once = 3 full O(n) partitions per body re-eval.
                    let bk = buckets
                    VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                        header
                        if viewModel.ingredients.isEmpty {
                            emptyStateCard
                        } else {
                            confirmedSection(buckets: bk)
                            needsReviewSection(buckets: bk)
                        }
                        solveButton
                    }
                    .padding(.horizontal, CGFloat.Stir.screenMargin)
                    .padding(.top, CGFloat.Stir.space3)
                    .padding(.bottom, CGFloat.Stir.space5)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.Stir.paper50.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Edit ingredient", isPresented: editAlertBinding) {
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
        // SCA-19 — full-screen scan-review tutorial. Suppressed during
        // the initial parse phase + before any ingredients have
        // landed; the cover mounts the first time the user has a real
        // ingredient list to read.
        .tutorial(
            key: .scanReview,
            content: { ScanReviewTutorial() },
            shouldPresent: viewModel.phase != .parsing
                && !viewModel.ingredients.isEmpty,
        )
    }

    // MARK: - Bucketing

    /// Single-pass partition. Order is preserved within each bucket.
    private var buckets: (confirmed: [ScanViewModel.Ingredient], needsReview: [ScanViewModel.Ingredient]) {
        var confirmed: [ScanViewModel.Ingredient] = []
        var needsReview: [ScanViewModel.Ingredient] = []
        for ingredient in viewModel.ingredients {
            if ingredient.confidence == .needsReview {
                needsReview.append(ingredient)
            } else {
                confirmed.append(ingredient)
            }
        }
        return (confirmed, needsReview)
    }

    // MARK: - Sections

    private var header: some View {
        // Thumbnail next to the title gives the user a visual anchor —
        // "this is what we looked at" — so retake-vs-edit is an obvious
        // call. UIImage(data:) is lazy: the JPEG is decoded once at
        // first paint and the wrapper costs ~nothing on body re-eval.
        //
        // SCA-35: when the user submitted multiple photos, the primary
        // thumbnail shows the first capture and a "+N" badge surfaces
        // the additional photos so the user knows they're reviewing a
        // merged result.
        HStack(alignment: .top, spacing: CGFloat.Stir.space3) {
            if let data = viewModel.primaryCapturedImageData,
               let image = UIImage(data: data) {
                ZStack(alignment: .bottomTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous))
                    if viewModel.capturedImages.count > 1 {
                        extraPhotoBadge
                    }
                }
                .accessibilityLabel(thumbnailA11yLabel)
            }
            VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
                Text("Scan review")
                    .stirFont(.displayLg)
                    .foregroundStyle(Color.Stir.ink900)
                    .accessibilityAddTraits(.isHeader)
                Text(headerSubtitle)
                    .stirFont(.bodyMd)
                    .foregroundStyle(Color.Stir.ink500)
            }
        }
    }

    private var extraPhotoBadge: some View {
        let extraCount = viewModel.capturedImages.count - 1
        return Text("+\(extraCount)")
            .stirFont(.labelMd)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.Stir.ink900.opacity(0.85), in: Capsule())
            .padding(4)
            .accessibilityHidden(true)
    }

    private var thumbnailA11yLabel: String {
        let count = viewModel.capturedImages.count
        if count <= 1 { return "Captured kitchen photo" }
        return "Captured \(count) kitchen photos"
    }

    private var headerSubtitle: String {
        let ingredientCount = viewModel.ingredients.count
        let ingredientNoun = ingredientCount == 1 ? "ingredient" : "ingredients"
        let imageCount = viewModel.capturedImages.count
        if imageCount > 1 {
            return "\(imageCount) photos · \(ingredientCount) \(ingredientNoun) found · tap to fix any miss"
        }
        return "\(ingredientCount) \(ingredientNoun) found · tap to fix any miss"
    }

    @ViewBuilder
    private func confirmedSection(buckets bk: (confirmed: [ScanViewModel.Ingredient], needsReview: [ScanViewModel.Ingredient])) -> some View {
        let confirmed = bk.confirmed
        if !confirmed.isEmpty {
            let needsReviewCount = bk.needsReview.count
            let visibleLimit = confirmedExpanded ? confirmed.count : Self.confirmedVisibleLimit
            // Lazy slice — no allocation per re-render. CA3-M4 fix.
            let visible = confirmed.prefix(visibleLimit)
            let overflow = confirmed.count - visible.count
            // Tail "+ Add" chip lives in the last rendered section so
            // there's only one add affordance no matter the bucket mix.
            let isLastSection = needsReviewCount == 0

            VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
                Text("CONFIRMED · \(confirmed.count)")
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.sage600)

                ChipFlowLayout(spacing: CGFloat.Stir.space2) {
                    ForEach(Array(visible)) { ingredient in
                        chipView(for: ingredient, style: chipStyle(for: ingredient.confidence))
                    }
                    if overflow > 0 {
                        moreChip(count: overflow)
                    }
                    if isLastSection {
                        addChip
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func needsReviewSection(buckets bk: (confirmed: [ScanViewModel.Ingredient], needsReview: [ScanViewModel.Ingredient])) -> some View {
        let needsReview = bk.needsReview
        if !needsReview.isEmpty {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
                Text("NEEDS REVIEW · \(needsReview.count)")
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.amber600)

                ChipFlowLayout(spacing: CGFloat.Stir.space2) {
                    ForEach(needsReview) { ingredient in
                        chipView(for: ingredient, style: .needsReview)
                    }
                    addChip
                }
            }
        }
    }

    @ViewBuilder
    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
            Text("Nothing to review yet")
                .stirFont(.labelLg)
                .foregroundStyle(Color.Stir.ink700)
            Text("Add an ingredient or swipe back to retake the scan.")
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink500)
            ChipFlowLayout(spacing: CGFloat.Stir.space2) {
                addChip
            }
        }
    }

    // MARK: - Chips

    private enum ChipStyle {
        case confirmed
        case likelyStaple
        case needsReview
    }

    private func chipStyle(for confidence: PantryParseResponse.PantryItemConfidence) -> ChipStyle {
        switch confidence {
        case .confirmed:    return .confirmed
        case .likelyStaple: return .likelyStaple
        case .needsReview:  return .needsReview
        }
    }

    private func chipView(for ingredient: ScanViewModel.Ingredient, style: ChipStyle) -> some View {
        Button {
            editTarget = ingredient
            editBuffer = ingredient.displayName
        } label: {
            chipLabel(text: ingredient.displayName, style: style)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44) // HIG tap-target floor (spec §8.2)
        .contextMenu {
            Button(role: .destructive) {
                viewModel.deleteIngredient(id: ingredient.id)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .accessibilityLabel("\(ingredient.displayName), \(accessibilitySuffix(style))")
        .accessibilityHint("Tap to edit")
    }

    @ViewBuilder
    private func chipLabel(text: String, style: ChipStyle) -> some View {
        Text(text)
            .stirFont(.labelMd)
            .foregroundStyle(chipForeground(style))
            .padding(.horizontal, CGFloat.Stir.space4)
            .padding(.vertical, Self.chipVerticalPadding)
            .background(chipBackground(style))
            .overlay(chipOverlay(style))
            .contentShape(Capsule())
    }

    private func chipForeground(_ style: ChipStyle) -> Color {
        switch style {
        case .confirmed:     return Color.Stir.ink900
        case .likelyStaple:  return Color.Stir.ink500 // lower emphasis — model is fairly sure but user should confirm staples
        case .needsReview:   return Color.Stir.amber600
        }
    }

    @ViewBuilder
    private func chipBackground(_ style: ChipStyle) -> some View {
        switch style {
        case .confirmed, .likelyStaple:
            Capsule(style: .continuous).fill(Color.Stir.paper200)
        case .needsReview:
            Capsule(style: .continuous).fill(Color.clear)
        }
    }

    @ViewBuilder
    private func chipOverlay(_ style: ChipStyle) -> some View {
        switch style {
        case .confirmed, .likelyStaple:
            EmptyView()
        case .needsReview:
            Capsule(style: .continuous)
                .strokeBorder(
                    Color.Stir.amber600,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3]),
                )
        }
    }

    private func accessibilitySuffix(_ style: ChipStyle) -> String {
        switch style {
        case .confirmed:    return "confirmed"
        case .likelyStaple: return "likely staple"
        case .needsReview:  return "needs review"
        }
    }

    private func moreChip(count: Int) -> some View {
        Button {
            confirmedExpanded = true
        } label: {
            Text("+ \(count) more")
                .stirFont(.labelMd)
                .foregroundStyle(Color.Stir.ink900)
                .padding(.horizontal, CGFloat.Stir.space4)
                .padding(.vertical, Self.chipVerticalPadding)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.Stir.paper200),
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityLabel("Show \(count) more confirmed items")
        .accessibilityHint("Tap to expand")
    }

    private var addChip: some View {
        Button {
            addBuffer = ""
            showAddAlert = true
        } label: {
            HStack(spacing: CGFloat.Stir.space1 + 2) { // 6pt icon-to-label
                Image(systemName: "plus")
                    // justification: 12pt inline plus glyph sized to match labelMd cap-height; matches mockup-04 §Review chip-scale add affordance
                    .font(.system(size: 12, weight: .semibold))
                Text("Add")
                    .stirFont(.labelMd)
            }
            .foregroundStyle(Color.Stir.ink500)
            .padding(.horizontal, CGFloat.Stir.space4)
            .padding(.vertical, Self.chipVerticalPadding)
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
        .frame(minHeight: 44)
        .accessibilityLabel("Add ingredient")
        .accessibilityHint("Opens a prompt to add a missing item")
    }

    // MARK: - CTA

    private var solveButton: some View {
        PrimaryButton(
            title: "Solve dinner",
            trailingIcon: Image(systemName: "arrow.right"),
            isDisabled: viewModel.ingredients.isEmpty,
            action: { onConfirm() },
        )
        .padding(.top, CGFloat.Stir.space3)
    }

    // MARK: - Loading & error

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
                    Capsule(style: .continuous)
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
        .stirCard()
    }

    // MARK: - Helpers

    private var editAlertBinding: Binding<Bool> {
        Binding(
            get: { editTarget != nil },
            set: { newValue in if !newValue { editTarget = nil } },
        )
    }
}
