// GroceryListView
//
// Mockup 12 "Aisle" view — aisle-grouped item rows with round
// checkbox + name + italic recipe attribution. Drives
// GroceryViewModel.generate() on first appear; exposes the Reminders
// export CTA when items are ready.
//
// Visual grammar (mockup 12):
//   - paper50 background
//   - Header row: back button + "Grocery" title + share (Reminders) CTA
//   - Hero stat row: big serif count + "items to buy · N already in pantry"
//   - Aisle sections: ember uppercase label + count + hairline divider
//   - Row: 22pt round checkbox (ink.300 outline → sage.600 fill checked),
//     item text (ink.900 → line-through/ink.500 when done), italic
//     recipe name right-aligned in ink.500
//   - Primary CTA bottom bar "Export to Reminders" (ember)
//   - Secondary bar state on Reminders-denied: "Copy list" / retry

import SwiftUI

struct GroceryListView: View {
    @Bindable var viewModel: GroceryViewModel
    let onDismiss: () -> Void

    @State private var remindersDeniedToast: Bool = false
    @State private var exportInFlight: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.stage {
                case .generating:
                    GeneratingView()
                case .ready:
                    // Branch on missingCount so a "you have everything"
                    // result doesn't render as the busted "0 items to
                    // buy · grouped by aisle" hero + a disabled grey
                    // Export button — that combination reads as a UI
                    // bug rather than a positive outcome. The model
                    // returns missing=0 when the pantry diff covers
                    // every recipe ingredient (legitimately, or via
                    // over-aggressive matching on vague names like
                    // "dried herbs"); either way the user has nothing
                    // to do here, so surface that affirmatively.
                    if viewModel.missingCount == 0 {
                        AllSetView(
                            recipeTitle: viewModel.recipePlan.title ?? "this recipe",
                            onDismiss: onDismiss,
                        )
                    } else {
                        readyBody
                    }
                case .exported:
                    ExportedView(onDismiss: onDismiss)
                case .error(let code, let message):
                    ErrorStateView(code: code, message: message, onRetry: {
                        Task { await viewModel.generate() }
                    })
                }
            }
            .background(Color.Stir.paper50.ignoresSafeArea())
            .navigationTitle("Grocery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onDismiss)
                        .foregroundStyle(Color.Stir.ink700)
                        .accessibilityLabel("Close")
                        .accessibilityHint("Dismisses the grocery list")
                }
            }
            .task {
                if viewModel.stage == .generating {
                    await viewModel.generate()
                }
            }
        }
    }

    // MARK: - Ready state

    @ViewBuilder
    private var readyBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroStat
                ForEach(viewModel.groupedItems, id: \.category) { group in
                    AisleSection(
                        category: group.category,
                        items: group.items,
                        onToggle: { viewModel.toggleChecked($0) },
                        recipeTitle: viewModel.recipePlan.title ?? "",
                    )
                }
                Spacer(minLength: 48)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .safeAreaInset(edge: .bottom) { footer }
        .overlay(alignment: .top) {
            if remindersDeniedToast {
                RemindersDeniedToast(onDismiss: { remindersDeniedToast = false })
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: remindersDeniedToast)
    }

    private var heroStat: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("\(viewModel.missingCount)")
                .stirFont(.displayLg)
                .foregroundStyle(Color.Stir.ink900)
            Text("items to buy · grouped by aisle")
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink500)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        Button {
            Task {
                exportInFlight = true
                let ok = await viewModel.exportToReminders()
                exportInFlight = false
                if !ok, viewModel.stage == .ready {
                    remindersDeniedToast = true
                }
            }
        } label: {
            HStack(spacing: 8) {
                if exportInFlight {
                    ProgressView().tint(.white)
                }
                Image(systemName: "checklist")
                    .font(.system(size: 14, weight: .semibold))
                Text(exportInFlight ? "Exporting…" : "Export to Reminders")
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(viewModel.missingCount == 0 ? Color.Stir.ink300 : Color.Stir.ember600),
            )
        }
        .disabled(viewModel.missingCount == 0 || exportInFlight)
        .accessibilityLabel(exportInFlight ? "Exporting" : "Export to Reminders")
        .accessibilityHint(viewModel.missingCount == 0
            ? "No missing ingredients to export"
            : "Sends your missing-ingredient list to Apple Reminders")
        .accessibilityAddTraits(exportInFlight ? [.updatesFrequently] : [])
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .background(Color.Stir.paper50.ignoresSafeArea(.all, edges: .bottom))
    }
}

// MARK: - Aisle section

private struct AisleSection: View {
    let category: GroceryCategory
    let items: [GroceryItem]
    let onToggle: (GroceryItem) -> Void
    let recipeTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(category.displayName)
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.ember600)
                Text("\(items.count)")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
                Rectangle()
                    .fill(Color.Stir.ink100)
                    .frame(height: 1)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2 }
            }
            ForEach(items, id: \.id) { item in
                AisleRow(
                    item: item,
                    recipeTitle: recipeTitle,
                    onToggle: { onToggle(item) },
                )
            }
        }
    }
}

private struct AisleRow: View {
    /// Core Data's NSManagedObject conforms to ObservableObject; SwiftUI
    /// picks up objectWillChange via KVO automatically, so a direct
    /// @ObservedObject binding redraws on every persisted mutation —
    /// no custom notification-center shim needed.
    @ObservedObject var item: GroceryItem
    let recipeTitle: String
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(item.isChecked ? Color.Stir.sage100 : .clear)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            item.isChecked ? Color.Stir.sage600 : Color.Stir.ink300,
                            lineWidth: 1.5,
                        )
                    if item.isChecked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.Stir.sage600)
                    }
                }
                .frame(width: 22, height: 22)
                .minTapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title(for: item))
            .accessibilityValue(item.isChecked ? "Checked" : "Not checked")
            .accessibilityAddTraits(item.isChecked ? [.isButton, .isSelected] : [.isButton])
            .accessibilityHint("Double-tap to toggle")

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title(for: item))
                    .stirFont(.bodyMd)
                    .fontWeight(.medium)
                    .foregroundStyle(item.isChecked ? Color.Stir.ink500 : Color.Stir.ink900)
                    .strikethrough(item.isChecked, color: Color.Stir.ink500)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if !recipeTitle.isEmpty {
                    Text(recipeTitle)
                        .stirFont(.bodySm)
                        .italic()
                        .foregroundStyle(Color.Stir.ink500)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func title(for item: GroceryItem) -> String {
        let name = item.displayName ?? ""
        guard let qty = item.quantityText?.trimmingCharacters(in: .whitespaces), !qty.isEmpty else {
            return name
        }
        return "\(name), \(qty)"
    }
}

// MARK: - Placeholder states

private struct GeneratingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(Color.Stir.ember600)
            Text("Building your list…")
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink500)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "You have everything" empty state — surfaced when the grocery
/// generator returns `missing=0`. Mirrors `ExportedView`'s sage-check
/// hero so the success grammar is consistent across the two terminal
/// states; copy carries the recipe title so the user understands
/// which dish was diffed (handy when the model over-matched and they
/// need to mentally double-check the pantry).
private struct AllSetView: View {
    let recipeTitle: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.Stir.sage100)
                    .frame(width: 72, height: 72)
                Image(systemName: "checkmark")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color.Stir.sage600)
            }
            Text("You're all set!")
                .stirFont(.displayMd)
                .foregroundStyle(Color.Stir.ink900)
            Text("Looks like you've got everything for \(recipeTitle).")
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink500)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button(action: onDismiss) {
                Text("Done")
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: 160, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.Stir.ember600),
                    )
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You're all set. You've got everything for \(recipeTitle).")
    }
}

private struct ExportedView: View {
    let onDismiss: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.Stir.sage100)
                    .frame(width: 72, height: 72)
                Image(systemName: "checkmark")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color.Stir.sage600)
            }
            Text("Sent to Reminders")
                .stirFont(.displayMd)
                .foregroundStyle(Color.Stir.ink900)
            Text("Open the Reminders app to check off items at the store.")
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink500)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button(action: onDismiss) {
                Text("Done")
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: 160, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.Stir.ember600),
                    )
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ErrorStateView: View {
    let code: String
    let message: String
    let onRetry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            Button(action: onRetry) {
                Text("Try again")
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.ember600)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.Stir.paper100)
        .padding(20)
    }
}

private struct RemindersDeniedToast: View {
    let onDismiss: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.Stir.rust600)
            Text("Reminders access is off. Open Settings → Privacy to enable.")
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink700)
                .lineLimit(2)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.Stir.ink500)
                    .minTapTarget()
            }
            .accessibilityLabel("Dismiss")
        }
        .frame(minHeight: 44)
        .padding(.horizontal, CGFloat.Stir.space3Half)
        .padding(.vertical, CGFloat.Stir.space2Half)
        .stirCard(
            borderColor: Color.Stir.ink100,
            radius: CGFloat.Stir.radiusMd,
        )
        .padding(.horizontal, CGFloat.Stir.space4Half)
    }
}
