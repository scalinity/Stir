// PantryAddSheet
//
// NavigationStack-rooted modal for manually adding a single pantry
// item. Three field rows — name (required), amount (optional), and
// memory-state segmented picker (Today / Standing) — plus a helper
// subtitle that flips with the picker selection so the user
// understands the cap-vs-no-cap tradeoff at the moment they make it.
//
// Token notes:
// - All text input goes through the canonical `InputField` component
//   (DesignSystem/Components/InputField.swift). Raw
//   `TextField(...).textFieldStyle(.roundedBorder)` would break the
//   12pt-radius / paper.100 / ink.900 / ember-focus grammar.
// - Title lives in the `.principal` toolbar slot so the navigation
//   bar renders the screen title in `.displaySm` (Stir display
//   serif) rather than the system fallback. Pattern set by
//   `HouseholdPreferencesView` and `OtherOptionsRoot`.
// - The `Picker(.segmented)` is the established Stir pattern for
//   binary memory-state choices — there is no Stir-DS segmented
//   control, and the system control reads cleanly against
//   `paper50`. See PantryRow.swift for the parallel state-badge
//   color tokens (sage = standing, amber = today).
// - Auto-focus on the name field via `@FocusState` so the keyboard
//   surfaces the moment the sheet opens — this is the single
//   highest-friction modal in the pantry surface and we don't want
//   the user to tap to focus.

import SwiftUI

struct PantryAddSheet: View {
    let onSave: (String, String?, PantryItem.MemoryState) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var amount: String = ""
    @State private var memoryState: PantryItem.MemoryState = .remembered
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space4) {
                nameField
                amountField
                memoryStateField
                Spacer()
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.top, CGFloat.Stir.space4)
            .background(Color.Stir.paper50)
            .navigationTitle("Add to pantry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .principal) {
                    Text("Add to pantry")
                        .stirFont(.displaySm)
                        .foregroundStyle(Color.Stir.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        commit()
                    }
                    .fontWeight(.semibold)
                    .disabled(trimmedName.isEmpty)
                }
            }
            .toolbarBackground(Color.Stir.paper50, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .onAppear { nameFocused = true }
    }

    // MARK: - Field rows

    private var nameField: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            fieldLabel("Ingredient")
            InputField(
                placeholder: "e.g. olive oil",
                text: $name,
                isFocused: nameFocused,
                autocapitalization: .words,
                submitLabel: .next,
            )
            .focused($nameFocused)
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

    /// Helper subtitle copy — flips with `memoryState` so the user
    /// sees the cap consequence at the moment they choose. The
    /// `.expired` and `.unknown` arms aren't reachable via the
    /// segmented picker but the switch is exhaustive on principle.
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
