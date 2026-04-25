// LeftoversPromptView
//
// Matches mockup 09 "Leftovers prompt" — sage micro-eyebrow with box
// icon, serif headline "Anything left over?", stacked item rows with
// checkmark tile + portion field, dashed "+ Add other" footer.
//
// Primary CTA "Find follow-up idea" kicks the
// `LeftoversSessionViewModel.findFollowUpIdea()` solve. Secondary
// "None" dismisses the flow.
//
// Trigger contract: presented ONLY when the feedback row's
// `leftoverCount > 0`. Never inferred.

import SwiftUI

struct LeftoversPromptView: View {
    @Bindable var viewModel: LeftoversSessionViewModel
    let onFindIdea: () async -> Void
    let onDismiss: () -> Void

    @State private var customName: String = ""
    @State private var customAmount: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    VStack(spacing: 10) {
                        ForEach(viewModel.items) { item in
                            ItemRow(
                                entry: item,
                                onToggle: { viewModel.toggle(item) },
                                onSetAmount: { viewModel.setAmount($0, for: item) },
                            )
                        }
                        AddCustomRow(
                            name: $customName,
                            amount: $customAmount,
                            onAdd: {
                                viewModel.addCustomItem(name: customName, amount: customAmount)
                                customName = ""
                                customAmount = ""
                            },
                        )
                    }

                    tip
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
            .background(Color.Stir.paper50.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { footer }
            .navigationTitle("Leftovers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onDismiss)
                        .foregroundStyle(Color.Stir.ink700)
                        .accessibilityLabel("Close")
                        .accessibilityHint("Dismisses the leftovers prompt")
                }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.Stir.sage600)
                Text("Log what's left")
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.sage600)
            }
            Text("Anything left over?")
                .stirFont(.displayXl)
                .foregroundStyle(Color.Stir.ink900)
            Text("Pick what's left and I'll look for a fast use-up tomorrow.")
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink500)
                .lineLimit(2)
        }
    }

    private var tip: some View {
        Group {
            if viewModel.selectedItems.isEmpty {
                Text("Select at least one item to see a tomorrow idea.")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.Stir.paper100),
                    )
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Tomorrow:")
                        .stirFont(.bodySm)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.Stir.ink700)
                    Text("I'll look for a quick use-up that leans on these \(viewModel.selectedItems.count) items.")
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.ink500)
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

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onDismiss) {
                Text("None")
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.ink700)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .stirCard(
                        borderColor: Color.Stir.ink100,
                        radius: CGFloat.Stir.radiusMd,
                    )
            }
            .accessibilityLabel("No leftovers")
            .accessibilityHint("Skips the leftovers flow")
            Button(action: { Task { await onFindIdea() } }) {
                Text(selectedCountLabel)
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(viewModel.selectedItems.isEmpty ? Color.Stir.ink300 : Color.Stir.ember600),
                    )
            }
            .disabled(viewModel.selectedItems.isEmpty)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(selectedCountLabel)
            .accessibilityHint(viewModel.selectedItems.isEmpty
                ? "Select at least one leftover item first"
                : "Submits your leftovers for a follow-up idea")
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .background(Color.Stir.paper50.ignoresSafeArea(.all, edges: .bottom))
    }

    private var selectedCountLabel: String {
        let n = viewModel.selectedItems.count
        switch n {
        case 0: return "Find follow-up idea"
        case 1: return "Find idea for 1 leftover"
        default: return "Find idea for \(n) leftovers"
        }
    }
}

// MARK: - Row components

private struct ItemRow: View {
    let entry: LeftoversEntry
    let onToggle: () -> Void
    let onSetAmount: (String) -> Void

    @State private var localAmount: String = ""
    @State private var seeded: Bool = false
    /// Debounce token so per-keystroke edits don't each hit the VM's
    /// items array. 300ms after the last change we commit the value
    /// through `onSetAmount`; mid-burst edits cancel the pending task.
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(entry.isSelected ? Color.Stir.sage600 : Color.clear)
                        .frame(width: 22, height: 22)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(entry.isSelected ? Color.Stir.sage600 : Color.Stir.ink300, lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                    if entry.isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .minTapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.displayName)
            .accessibilityValue(entry.isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(entry.isSelected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityHint("Double-tap to toggle")

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.ink900)
                    .lineLimit(1)
                if let amount = entry.approximateAmountText, !amount.isEmpty {
                    Text(amount)
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.ink500)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            TextField("Amount", text: $localAmount)
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink700)
                .multilineTextAlignment(.trailing)
                .frame(width: 84)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous).fill(Color.Stir.paper50),
                )
                .overlay(
                    Capsule(style: .continuous).strokeBorder(Color.Stir.ink100, lineWidth: 1),
                )
                .onChange(of: localAmount) { _, new in
                    debounceTask?.cancel()
                    debounceTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        onSetAmount(new)
                    }
                }
                .onSubmit {
                    debounceTask?.cancel()
                    onSetAmount(localAmount)
                }
        }
        .padding(CGFloat.Stir.space3Half)
        .stirCard(
            fill: entry.isSelected ? Color.Stir.sage100 : Color.Stir.paper100,
            borderColor: entry.isSelected ? Color.Stir.sage600 : Color.Stir.ink100,
        )
        .onAppear {
            if !seeded {
                localAmount = entry.approximateAmountText ?? ""
                seeded = true
            }
        }
    }
}

private struct AddCustomRow: View {
    @Binding var name: String
    @Binding var amount: String
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField("Add other…", text: $name)
                .stirFont(.bodyMd)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.Stir.paper50),
                )
            TextField("Amount", text: $amount)
                .stirFont(.bodySm)
                .frame(width: 84)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.Stir.paper50),
                )
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(name.isEmpty ? Color.Stir.ink300 : Color.Stir.ember600)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.Stir.paper100),
                    )
                    .minTapTarget()
            }
            .accessibilityLabel("Add leftover item")
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                .foregroundStyle(Color.Stir.ink300),
        )
    }
}
