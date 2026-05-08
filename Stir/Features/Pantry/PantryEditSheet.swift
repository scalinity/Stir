// PantryEditSheet
//
// NavigationStack-rooted modal for editing an existing pantry item.
// Mirrors `PantryAddSheet`'s field layout (name, optional amount,
// memory-state segmented picker) and adds a destructive
// "Remove from pantry" button at the bottom — the only path to
// destroy a pantry row outside swipe-to-delete on the list.
//
// State seeded from the passed-in `PantryItem` via
// `_field = State(initialValue: ...)` in `init`. Auto-focus is
// deliberately NOT applied: the user is editing, not creating, so
// the keyboard should not surface unsolicited. A `@FocusState`
// binding is wired regardless so `InputField`'s ember-600 focus
// border surfaces when the user taps in (review W17).
//
// Memory-state preservation: the picker only exposes `.ephemeral` /
// `.remembered`. An `.expired` or `.unknown` row used to be coerced
// to `.remembered` in init and silently rewritten on save (review
// C3). Now the original `MemoryState` is preserved and the saved
// memoryState is `nil` (= "no change") when the user doesn't move
// the picker — `onSave` carries an Optional which the caller
// translates to "skip the memoryState update entirely."
//
// Tombstone race: `item` is observed as `@ObservedObject`. If
// CloudKit-merge sets `deletedAt` while the sheet is open, the
// `.onChange` handler dismisses and surfaces a typed toast via the
// VM's `surfaceExternallyRemoved()` (review W3).

import SwiftUI

struct PantryEditSheet: View {
    /// Direct NSManagedObject binding so a CloudKit-merge that sets
    /// `deletedAt` on the row triggers an `.onChange` that dismisses
    /// the sheet (review W3). Same KVO pattern as `PantryRow`.
    @ObservedObject var item: PantryItem
    let onSave: (String, String?, PantryItem.MemoryState?) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void
    /// Closure invoked when the row's `deletedAt` flips to non-nil
    /// during the sheet's lifetime. View hoists this to the VM's
    /// `surfaceExternallyRemoved()` so a typed toast fires.
    let onExternallyRemoved: () -> Void

    @State private var name: String
    @State private var amount: String
    /// `nil` = "user did not move the picker; preserve the row's
    /// existing memoryState." Set to a concrete value the moment
    /// the picker selection changes via `.onChange`. Initial picker
    /// segment is derived from the row's current state but doesn't
    /// pre-commit a change to the parent on Save.
    @State private var pickerSelection: PantryItem.MemoryState
    @State private var pickerWasMoved: Bool = false

    @FocusState private var nameFocused: Bool
    @FocusState private var amountFocused: Bool

    init(
        item: PantryItem,
        onSave: @escaping (String, String?, PantryItem.MemoryState?) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onExternallyRemoved: @escaping () -> Void,
    ) {
        self.item = item
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        self.onExternallyRemoved = onExternallyRemoved
        _name = State(initialValue: item.displayName ?? "")
        _amount = State(initialValue: item.amountText ?? "")
        // Picker segment derives from current state but is purely
        // visual until the user moves it. `.expired`/`.unknown` show
        // as "Standing" because the picker doesn't expose those
        // segments — but committing without a touch leaves the row's
        // actual `.expired`/`.unknown` state intact (review C3).
        let initial = item.typedMemoryState
        let visualSegment: PantryItem.MemoryState =
            (initial == .ephemeral) ? .ephemeral : .remembered
        _pickerSelection = State(initialValue: visualSegment)
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
                        .stirFont(.bodyMd)
                        .foregroundStyle(Color.Stir.ember600)
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
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.ember600)
                    .disabled(name.pantryTrimmed.isEmpty)
                }
            }
            .toolbarBackground(Color.Stir.paper50, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            // Length caps applied at the input layer for immediate
            // user feedback — repository validation guards repeat the
            // check defense-in-depth (review W10).
            .onChange(of: name) { _, newValue in
                if newValue.count > PantryItemRepository.maxDisplayNameLength {
                    name = String(newValue.prefix(PantryItemRepository.maxDisplayNameLength))
                }
            }
            .onChange(of: amount) { _, newValue in
                if newValue.count > PantryItemRepository.maxAmountTextLength {
                    amount = String(newValue.prefix(PantryItemRepository.maxAmountTextLength))
                }
            }
            // Picker movement records the pickerWasMoved flag so
            // commit() knows whether to send `memoryState` or `nil`.
            .onChange(of: pickerSelection) { _, _ in
                pickerWasMoved = true
            }
            // Tombstone race: row got soft-deleted while user was
            // editing (e.g. CloudKit merge, swipe-delete on another
            // device). Dismiss + signal the VM (review W3).
            .onChange(of: item.deletedAt) { _, newValue in
                if newValue != nil {
                    onExternallyRemoved()
                }
            }
        }
    }

    // MARK: - Field rows

    private var nameField: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            pantryFieldLabel("Ingredient")
            InputField(
                placeholder: "e.g. olive oil",
                text: $name,
                isFocused: nameFocused,
                autocapitalization: .words,
                submitLabel: .next,
                onSubmit: { amountFocused = true },
            )
            .focused($nameFocused)
        }
    }

    private var amountField: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            pantryFieldLabel("Amount (optional)")
            InputField(
                placeholder: "e.g. 2 tbsp, 500g, half a bottle",
                text: $amount,
                isFocused: amountFocused,
                autocapitalization: .never,
                submitLabel: .done,
                onSubmit: { commit() },
            )
            .focused($amountFocused)
        }
    }

    private var memoryStateField: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            pantryFieldLabel("Keep on hand")
            Picker("Memory state", selection: $pickerSelection) {
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
        // ember700 is the canonical destructive-action tint in the
        // warm palette — matches SavedMealsView's swipe-to-delete and
        // the swipe action on `PantryListView`'s rows. Was rust600
        // (an error/warning text color), which read as "soft warning"
        // rather than "destructive action".
        .tint(Color.Stir.ember700)
    }

    // MARK: - Helpers

    /// Helper subtitle copy — flips with `pickerSelection`. Same
    /// string pair as `PantryAddSheet`; intentionally duplicated
    /// rather than extracted because pulling a shared helper
    /// introduces cross-file coupling for two strings.
    private var memoryStateSubtitle: String {
        switch pickerSelection {
        case .ephemeral:
            return "Used for tonight's solve only — won't count against your saved pantry."
        case .remembered:
            return "Counts toward your saved pantry. Used for every solve until removed."
        case .expired, .unknown:
            return ""
        }
    }

    private func commit() {
        let trimmed = name.pantryTrimmed
        guard !trimmed.isEmpty else { return }
        // memoryState = nil means "preserve the row's existing
        // memoryState" — sent only when the user actually moved the
        // picker. Otherwise an `.expired` row that the user merely
        // renamed would silently flip to `.remembered` (review C3).
        let memoryStateToCommit: PantryItem.MemoryState? = pickerWasMoved ? pickerSelection : nil
        onSave(trimmed, amount.pantryTrimmedOrNil, memoryStateToCommit)
    }
}
