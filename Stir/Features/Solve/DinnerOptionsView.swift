// DinnerOptionsView
//
// Renders 3 dish cards as they stream in. Skeleton placeholders before
// each arrives; progressive fill as the SSE events land. Tapping a card
// pushes DishPreviewView.

import SwiftUI

struct DinnerOptionsView: View {
    @Bindable var viewModel: SolveViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                ForEach(viewModel.slots) { slot in
                    slotCard(slot)
                }
            }
            .padding()
        }
        .navigationTitle("Tonight's options")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "solve-once") {
            // First-appearance trigger ONLY if the stream hasn't started yet.
            if viewModel.phase == .constraints {
                viewModel.startSolve()
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Three that fit tonight")
                .font(.title3.weight(.semibold))
            if viewModel.phase == .solving {
                Text("Looking at your pantry and constraints…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if viewModel.slots.allSatisfy({ $0.dish == nil && $0.errorCode == nil }) {
                Text("Preparing…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func slotCard(_ slot: SolveViewModel.SlotState) -> some View {
        if let dish = slot.dish {
            NavigationLink(value: dish) {
                DishCardView(dish: dish)
            }
            .buttonStyle(.plain)
        } else if let code = slot.errorCode {
            errorSlot(rank: slot.rank, code: code)
        } else {
            skeletonSlot(rank: slot.rank)
        }
    }

    private func skeletonSlot(rank: Int) -> some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color(.tertiarySystemFill))
            .frame(height: 104)
            .overlay(alignment: .topLeading) {
                Text("Rank \(rank)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
            .overlay(
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.secondary),
            )
    }

    private func errorSlot(rank: Int, code: ErrorCode) -> some View {
        // `code` is preserved in the signature for future per-code copy
        // (AI-02 vs AI-01) but isn't surfaced distinctly in step-3 UI.
        let _ = code
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Option \(rank) didn't pass your rules.")
                    .font(.subheadline.weight(.semibold))
                Text("Try loosening one constraint and re-solving.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1),
        )
    }
}

// MARK: - DishCardView

struct DishCardView: View {
    let dish: DishCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(dish.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Text("\(dish.totalTimeMinutes) min")
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(dish.whyItFits)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                label(text: dish.fitLabelPrimary, tint: tint(for: dish.fitLabelPrimary))
                if let secondary = dish.fitLabelSecondary {
                    label(text: secondary, tint: .secondary)
                }
                Spacer()
                if dish.missingIngredientCount > 0 {
                    Label("\(dish.missingIngredientCount) missing", systemImage: "cart")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func label(text: String, tint: Color) -> some View {
        Text(text.replacingOccurrences(of: "_", with: " "))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.2), in: Capsule())
            .foregroundStyle(tint)
            .textCase(.uppercase)
    }

    private func tint(for label: String) -> Color {
        switch label {
        case "fastest":            return .orange
        case "least_waste":        return .green
        case "best_fit":           return .blue
        case "uses_what_you_have": return .teal
        case "new_to_you":         return .purple
        default:                    return .secondary
        }
    }
}
