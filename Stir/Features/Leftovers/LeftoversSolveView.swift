// LeftoversSolveView
//
// Matches mockup 09 "Leftover Solve — tomorrow's options". Sage
// pill-strip shows the leftovers the solve was based on; three option
// cards fill the body with the first highlighted as "BEST FIT".
// Primary CTA saves the selection; secondary dismisses.
//
// Rendered inside LeftoversRoot after the VM transitions to `.options`.
// While the VM is `.solving`, a progress pulse fills the same layout
// so the user sees progress without a layout jump when the first dish
// arrives.

import SwiftUI

struct LeftoversSolveView: View {
    @Bindable var viewModel: LeftoversSessionViewModel
    let onSelect: (DishCard) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 12)

            if !viewModel.selectedItems.isEmpty {
                LeftoversChipStrip(items: viewModel.selectedItems)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
            }

            contentBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 20)

            footer
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 20)
        }
        .background(Color.Stir.paper50.ignoresSafeArea())
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.Stir.sage600)
                Text("\(viewModel.selectedItems.count) leftovers · tomorrow")
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.sage600)
            }
            Text("Tomorrow, built from tonight.")
                .stirFont(.displayLg)
                .foregroundStyle(Color.Stir.ink900)
                .lineLimit(2)
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var contentBody: some View {
        switch viewModel.stage {
        case .solving where viewModel.dishes.isEmpty:
            SolvingSkeleton()
        case .options, .solving:
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(viewModel.dishes.enumerated()), id: \.element.id) { idx, dish in
                        LeftoversOptionCard(dish: dish, isBestFit: idx == 0, onTap: { onSelect(dish) })
                    }
                    helperText
                }
                .padding(.top, 4)
            }
        case .error(let code, let message):
            ErrorView(code: code, message: message)
        case .prompt:
            // Shouldn't happen — the root swaps to prompt view before solve
            EmptyView()
        }
    }

    private var helperText: some View {
        Text("Saving one of these adds it to tomorrow's Tonight. Change anytime.")
            .stirFont(.bodySm)
            .foregroundStyle(Color.Stir.ink500)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.Stir.paper100),
            )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onDismiss) {
                Text("Not tomorrow")
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.ink700)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.Stir.paper100),
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.Stir.ink100, lineWidth: 1),
                    )
            }
        }
    }
}

// MARK: - Dish card

private struct LeftoversOptionCard: View {
    let dish: DishCard
    let isBestFit: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.Stir.paper200)
                    .frame(width: 52, height: 52)
                    .overlay(
                        Text(emoji(for: dish))
                            .font(.system(size: 22)),
                    )

                VStack(alignment: .leading, spacing: 3) {
                    if isBestFit {
                        Text("Best fit")
                            .stirFont(.labelMicroEyebrow)
                            .foregroundStyle(Color.Stir.ember600)
                    }
                    Text(dish.title)
                        .stirFont(.labelLg)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.Stir.ink900)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.Stir.ink500)
                        Text("\(dish.totalTimeMinutes) min")
                            .stirFont(.bodySm)
                            .foregroundStyle(Color.Stir.ink500)
                        Text("·").foregroundStyle(Color.Stir.ink500)
                        Text(dish.whyItFits)
                            .stirFont(.bodySm)
                            .foregroundStyle(Color.Stir.ink500)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Stir.ink500)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isBestFit ? Color.Stir.ember100 : Color.Stir.paper100),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isBestFit ? Color.Stir.ember600 : Color.Stir.ink100,
                        lineWidth: isBestFit ? 1.5 : 1,
                    ),
            )
        }
        .buttonStyle(.plain)
    }

    private func emoji(for dish: DishCard) -> String {
        switch dish.recipePlan.cuisine?.lowercased() {
        case "italian", "pasta": return "🍝"
        case "mexican": return "🌮"
        case "chinese", "asian": return "🥡"
        case "japanese": return "🍱"
        case "thai": return "🍜"
        case "indian": return "🍛"
        case "american", "bbq": return "🍔"
        case "breakfast": return "🍳"
        case "soup": return "🥣"
        case "salad": return "🥗"
        case "seafood", "fish": return "🐟"
        default: return "🍽️"
        }
    }
}

// MARK: - Chip strip

private struct LeftoversChipStrip: View {
    let items: [LeftoversEntry]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    Chip(text: chipLabel(for: item))
                }
            }
        }
    }

    private func chipLabel(for item: LeftoversEntry) -> String {
        if let amt = item.approximateAmountText, !amt.isEmpty {
            return "\(item.displayName) · \(amt)"
        }
        return item.displayName
    }

    private struct Chip: View {
        let text: String
        var body: some View {
            Text(text)
                .stirFont(.bodySm)
                .fontWeight(.semibold)
                .foregroundStyle(Color.Stir.sage600)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous).fill(Color.Stir.sage100),
                )
                .overlay(
                    Capsule(style: .continuous).strokeBorder(Color.Stir.sage600, lineWidth: 1),
                )
        }
    }
}

// MARK: - Skeleton / error

private struct SolvingSkeleton: View {
    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.Stir.paper200)
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.Stir.paper200)
                            .frame(height: 14)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.Stir.paper200)
                            .frame(width: 140, height: 10)
                    }
                    Spacer(minLength: 6)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.Stir.paper100),
                )
            }
            HStack {
                ProgressView()
                    .tint(Color.Stir.ember600)
                Text("Looking at your leftovers…")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
                Spacer()
            }
            .padding(.top, 8)
        }
    }
}

private struct ErrorView: View {
    let code: String
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.Stir.rust600)
                Text(code)
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.rust600)
            }
            Text(message)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink700)
                .lineLimit(3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.Stir.paper100),
        )
    }
}
