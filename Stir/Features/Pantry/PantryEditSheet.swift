// PantryEditSheet
//
// NavigationStack-rooted modal for editing an existing pantry item.
// Mirrors `PantryAddSheet`'s field layout (name, optional amount,
// memory-state segmented picker) and adds a destructive
// "Remove from pantry" button at the bottom — the only path to
// destroy a pantry row outside swipe-to-delete on the list.
//
// State is pre-populated from the passed-in `PantryItem` via
// `_field = State(initialValue: ...)` in `init`. Auto-focus is
// deliberately NOT applied: the user is editing, not creating, so
// the keyboard should not surface unsolicited.
//
// Token notes:
// - The destructive button uses `Color.Stir.rust600` (the only
//   rust shade present) — `rust100` was caught in the Task 6 review
//   as nonexistent. `crimson100/600` is the alternative paired pair,
//   but the soft-error / "remove" semantic specifically reads as
//   rust600 per `Image.Stir.softError`'s color contract.
// - The trash glyph routes through `Image.Stir.delete` (canonical
//   "Delete" alias for `trash` in the icon namespace) rather than
//   raw `Image(systemName: "trash")`.
// - All other tokens (InputField, principal-slot title, segmented
//   picker, helper subtitle) match `PantryAddSheet`. Sister-task
//   intent: change one, change both.

import SwiftUI

struct PantryEditSheet: View {
    let onSave: (String, String?, PantryItem.MemoryState) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var amount: String
    @State private var memoryState: PantryItem.MemoryState

    init(
        item: PantryItem,
        onSave: @escaping (String, String?, PantryItem.MemoryState) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void,
    ) {
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _name = State(initialValue: item.displayName ?? "")
        _amount = State(initialValue: item.amountText ?? "")
        // `.expired`/`.unknown` round-trip through the segmented
        // picker as `.remembered` — the user can re-mark "Today" if
        // they want to revert. Avoiding a "frozen on expired" state
        // matches the soft-decay model in PantryItem+Extensions.
        let initial = item.typedMemoryState
        _memoryState = State(initialValue: (initial == .ephemeral) ? .ephemeral : .remembered)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space4) {
                nameField
                amountField
                memoryStateField
                Spacer()
                deleteButton
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.top, CGFloat.Stir.space4)
            .padding(.bottom, CGFloat.Stir.space4)
            .background(Color.Stir.paper50)
            .navigationTitle("Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .principal) {
                    Text("Edit item")
                        .stirFont(.displaySm)
                        .foregroundStyle(Color.Stir.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        commit()
                    }
                    .fontWeight(.semibold)
                    .disabled(trimmedName.isEmpty)
                }
            }
            .toolbarBackground(Color.Stir.paper50, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    // MARK: - Field rows

    private var nameField: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            fieldLabel("Ingredient")
            InputField(
                placeholder: "e.g. olive oil",
                text: $name,
                autocapitalization: .words,
                submitLabel: .next,
            )
        }
    }

    private var amountField: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            fieldLabel("Amount (optional)")
            InputField(
                placeholder: "e.g. 2 tbsp, 500g, half a bottle",
                text: $amount,
                autocapitalization: .never,
                submitLabel: .done,
            )
        }
    }

    private var memoryStateField: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            fieldLabel("Keep on hand")
            Picker("Memory state", selection: $memoryState) {
                Text("Today").tag(PantryItem.MemoryState.ephemeral)
                Text("Standing").tag(PantryItem.MemoryState.remembered)
            }
            .pickerStyle(.segmented)

            Text(memoryStateSubtitle)
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            HStack(spacing: CGFloat.Stir.space2) {
                Image.Stir.delete
                Text("Remove from pantry")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, CGFloat.Stir.space2)
        }
        .buttonStyle(.bordered)
        .tint(Color.Stir.rust600)
    }

    // MARK: - Helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.ink500)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAmount: String? {
        let t = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Helper subtitle copy — flips with `memoryState`. Same string
    /// pair as `PantryAddSheet`; intentionally duplicated rather
    /// than extracted because pulling a shared helper introduces
    /// cross-file coupling for two strings, and the sister-task
    /// review caught that the shared helpers it tried to extract
    /// added more weight than they removed.
    private var memoryStateSubtitle: String {
        switch memoryState {
        case .ephemeral:
            return "Used for tonight's solve only — won't count against your saved pantry."
        case .remembered:
            return "Counts toward your saved pantry. Used for every solve until removed."
        case .expired, .unknown:
            return ""
        }
    }

    private func commit() {
        let trimmed = trimmedName
        guard !trimmed.isEmpty else { return }
        onSave(trimmed, trimmedAmount, memoryState)
    }
}
