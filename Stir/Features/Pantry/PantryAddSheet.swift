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
    @FocusState private var amountFocused: Bool

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
            .navigationBarTitleDisplayMode(.inline)
            // SCA-457: drop the system toolbar (iOS 26 paints every
            // ToolbarItem child with the Liquid Glass material) and
            // render a custom top bar via .stirTopBar that lives outside
            // the toolbar context.
            .stirTopBar(
                title: "Add to pantry",
                leading: {
                    StirTopBarTextButton("Cancel") { onCancel() }
                },
                trailing: {
                    StirTopBarTextButton(
                        "Add",
                        emphasis: .prominent,
                        isEnabled: !name.pantryTrimmed.isEmpty,
                    ) { commit() }
                },
            )
            // Length caps at the input layer give immediate feedback
            // (review W10). Repository validation guards repeat the
            // check defense-in-depth so non-UI callers stay safe.
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
        }
        .onAppear { nameFocused = true }
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
        let trimmed = name.pantryTrimmed
        guard !trimmed.isEmpty else { return }
        onSave(trimmed, amount.pantryTrimmedOrNil, memoryState)
    }
}

// MARK: - Shared pantry-sheet helpers (SCA-103)
//
// Pre-SCA-103: PantryAddSheet and PantryEditSheet each carried a
// private `fieldLabel(_:)` helper plus `trimmedName` / `trimmedAmount`
// computed properties. The implementations were identical and any
// styling change had to be made in both places.
//
// SCA-103 lifts them to file scope here. Module-level visibility
// (`internal` by default) makes them reachable from PantryEditSheet
// without crossing target boundaries. Living next to the larger of
// the two sheets keeps the helpers near a representative call site.
// File scope keeps the pbxproj clean — no new file reference, no
// `Compile Sources` build-phase entry.
//
// `commit()` was NOT lifted: the two sheets resolve `memoryState`
// differently (Add commits the picker as `.remembered` | `.ephemeral`;
// Edit only commits the picker if `pickerWasMoved`, preserving
// `.expired` rows that were merely renamed). Lifting requires
// parameterizing the divergent step, which costs more than the
// duplicated 4 lines saves.

/// Pantry-sheet eyebrow label (uppercased text in `.labelEyebrow` at
/// `ink500`). Used above each input field to mirror Stir's
/// labeled-form pattern.
@ViewBuilder
func pantryFieldLabel(_ text: String) -> some View {
    Text(text.uppercased())
        .stirFont(.labelEyebrow)
        .foregroundStyle(Color.Stir.ink500)
}

extension String {
    /// Whitespace-trimmed value (always non-nil). Used by pantry-sheet
    /// `name` fields where validity is checked separately via `.isEmpty`
    /// (the call-site needs to disable a button or short-circuit
    /// `commit()`).
    var pantryTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whitespace-trimmed value, or `nil` if empty after trimming.
    /// Used by pantry-sheet `amount` fields where empty input means
    /// "no amount" — the call-site forwards `nil` to the persistence
    /// layer rather than the empty string.
    var pantryTrimmedOrNil: String? {
        let trimmed = pantryTrimmed
        return trimmed.isEmpty ? nil : trimmed
    }
}
