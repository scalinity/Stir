// PantryListView
//
// Settings → "Manage pantry" destination. Lists the household's
// PantryItems (NSManagedObject-bound rows for live KVO redraws via
// PantryRow) with swipe-to-delete + tap-to-edit. Top-of-list shows
// current REMEMBERED count vs cap so users see headroom; tapping the
// toolbar "+" opens PantryAddSheet, with the repository's cap-aware
// insert routing to the paywall when over-cap.
//
// Empty state mirrors TonightHomeView's first-use grammar (large
// ember-tinted icon tile + title + subtitle + primary CTA) but
// points at scan as the primary populate path with manual-add as
// the fallback.
//
// Coordinator is passed explicitly (not pulled from `@Environment`)
// because this screen brokers two coordinator surfaces — the pantry
// repository and `presentPaywall(_:)` — and the parameter form makes
// the dependency contract visible to callers (Settings entry-point
// in Task 10).
//
// Toast surface: `vm.errorEvent` (UUID-stamped) drives a `.stirToast`
// at the outer Group via `.onChange`. A separate
// `vm.externallyRemovedItemEvent` handles the CloudKit-tombstone race
// where an open edit sheet's row gets soft-deleted from another
// device — the sheet auto-dismisses and a typed toast surfaces.

import OSLog
import SwiftUI

struct PantryListView: View {
    /// SCA-101 (d) review S3: name the debounce so a future tuner
    /// finds it immediately. 150ms is the lower bound where typeahead
    /// still feels responsive on iPhone 17 Pro at 1000-row Pro
    /// pantries; tighten only if Instruments shows otherwise.
    private static let searchDebounce: Duration = .milliseconds(150)

    let coordinator: RootCoordinator

    @Environment(EntitlementService.self) private var entitlements
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: PantryListViewModel?
    @State private var showingAddSheet = false
    @State private var editingItem: PantryItem?
    @State private var initError: String?
    @State private var errorToast: StirToastPayload?
    @State private var showingDeleteAllConfirmation = false

    /// Hoisted as a positive boolean (vs the triple-negative
    /// `viewModel?.items.isEmpty == false`). Picks which in-list
    /// pantry tutorial variant fires — see `inListTutorialKey`.
    private var pantryHasItems: Bool {
        viewModel?.items.isEmpty == false
    }

    /// Single TutorialKey for the in-list walkthrough; flips between
    /// the populated and empty variants based on `pantryHasItems`.
    /// Mounting one `.tutorial(key: ...)` keyed off this selector
    /// (rather than two siblings each gated on opposite polarity of
    /// `pantryHasItems`) prevents the SCA-28 C2 race where a
    /// CloudKit sync mid-presentation would trigger a concurrent
    /// fullScreenCover and corrupt the funnel. The host's
    /// `TutorialPresenterModifier` re-mounts the cover when this
    /// key changes, which preserves the distinct-keys SCA-17 C4
    /// design (each variant owns its own UserDefaults flag).
    private var inListTutorialKey: TutorialKey {
        pantryHasItems ? .pantryInListTour : .pantryInListTourEmpty
    }

    var body: some View {
        Group {
            if let viewModel {
                listBody(vm: viewModel)
            } else if let message = initError {
                // Profile unavailable at task-time — Settings is reachable
                // pre-bootstrap on cold deeplink launches. ConfigurationErrorView's
                // `onRetry` action genuinely retries: clear `initError`,
                // SwiftUI re-runs the `.task` modifier on the next render
                // when the conditional flips back to the loading branch.
                // Previously the closure dismissed the screen, which
                // contradicted the "Try again" button copy.
                ConfigurationErrorView(message: message, onRetry: {
                    initError = nil
                })
                .background(Color.Stir.paper50)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.Stir.paper50)
            }
        }
        .navigationTitle("Pantry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddSheet = true
                } label: {
                    Label { Text("Add item") } icon: { Image.Stir.plus }
                }
                .disabled(viewModel == nil)
            }
        }
        // SCA-54: searchable lives at the screen-level Group (not the
        // inner List inside `populatedList`) so iOS owns the transition
        // between the pinned navigation-bar drawer and the scrolling
        // List below. Attaching to the inner List left iOS computing
        // the collapse animation against the nav-bar context while the
        // actual scroll target was a List sitting under a non-scrolling
        // header strip — that layout discontinuity made the very first
        // scroll engagement jump rather than smooth-collapse. Drawer
        // placement `.always` keeps the bar visible across scroll
        // states so the affordance is steady. Binding routes through
        // an Optional-unwrap that no-ops while the VM is still loading
        // (the searchable is gated visually by the `if let viewModel`
        // branch in `listBody`, so a stray write during loading is
        // harmless either way).
        .searchable(
            text: Binding(
                get: { viewModel?.searchText ?? "" },
                set: { viewModel?.searchText = $0 },
            ),
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search pantry",
        )
        // SCA-101 (d): debounce filter recompute by `searchDebounce`.
        // The text field stays responsive (binding above writes per
        // keystroke) but `effectiveSearchText` — which `filteredItems`
        // reads — only catches up after the user stops typing for
        // 150ms. Pro-tier 1000-row pantries pay the filter cost once
        // per pause instead of per keystroke. Cancellation via
        // `.task(id:)` ensures only the latest sleep wins.
        .task(id: viewModel?.searchText) {
            guard let vm = viewModel else { return }
            // Capture the current value to compare after the sleep.
            let pending = vm.searchText
            do {
                try await Task.sleep(for: Self.searchDebounce)
            } catch {
                return // task cancelled by next keystroke
            }
            // Review W2: re-bind `viewModel` post-sleep and ensure the
            // VM identity hasn't changed — if the parent reassigns
            // `viewModel` mid-debounce (e.g. household swap, profile
            // re-init), the captured `vm` would be the orphaned
            // instance and writing to it would silently lose the
            // debounced text. The `===` check skips the stale write
            // and lets the new VM's own .task fire on its own
            // searchText id. The `searchText == pending` re-check
            // defends against the (mostly theoretical) case where
            // .task(id:) fired but cancellation was lost between
            // siblings.
            guard let liveVM = viewModel, liveVM === vm else { return }
            if liveVM.searchText == pending {
                liveVM.effectiveSearchText = pending
            }
        }
        // SCA-19 / SCA-28 — full-screen in-list Pantry walkthrough.
        // SCA-28 C2 collapsed the prior two-`.tutorial(...)` mount
        // into a single modifier keyed off `inListTutorialKey`. Two
        // siblings could otherwise fire concurrent fullScreenCovers
        // when a CloudKit sync flipped `pantryHasItems` mid-tour:
        // the empty cover would dismiss without `markCompleted` and
        // the populated cover would replace it, corrupting the
        // PostHog funnel (`tutorial_started` without a matching
        // resolution). Distinct-key design (SCA-17 C4) is preserved
        // because each variant still owns its own `TutorialKey` /
        // UserDefaults flag — completing one does NOT burn the other.
        // Cross-variant `!isCompleted(otherKey)` belt-and-suspenders
        // ensures an in-flight resolution can't trigger the alternate.
        .tutorial(
            key: inListTutorialKey,
            content: {
                Group {
                    if pantryHasItems {
                        PantryInListPopulatedTutorial()
                    } else {
                        PantryInListEmptyTutorial()
                    }
                }
            },
            shouldPresent: viewModel?.didCompleteInitialLoad == true
                && (viewModel?.searchText.isEmpty ?? true),
        )
        // AddSheet hoisted to outer Group so it survives empty→populated
        // subtree swaps. Toolbar `+` is disabled while VM is nil so the
        // `if let` branch always lands. On `.failed` the sheet stays
        // open (review S11) so the user's input isn't silently lost; a
        // toast surfaces via the errorEvent binding below.
        .sheet(isPresented: $showingAddSheet) {
            if let viewModel {
                PantryAddSheet(
                    onSave: { name, amount, state in
                        let result = viewModel.addItem(displayName: name, amountText: amount, memoryState: state)
                        switch result {
                        case .added:
                            showingAddSheet = false
                        case .capReached:
                            showingAddSheet = false
                            coordinator.presentPaywall(.pantryCapReached)
                        case .failed:
                            // Keep sheet open; toast surfaces via errorEvent.
                            // User's input is preserved so they can retry
                            // without re-typing.
                            break
                        }
                    },
                    onCancel: { showingAddSheet = false },
                )
            }
        }
        // Toast wiring extracted to a modifier so the outer body
        // doesn't tip over the SwiftUI typecheck-complexity ceiling
        // (the .sheet closures + 3 .onChanges + .stirToast push the
        // expression past it). Functionally identical to inlining.
        .modifier(PantryToastModifier(
            viewModel: viewModel,
            errorToast: $errorToast,
            editingItem: $editingItem,
        ))
        .task {
            guard viewModel == nil else { return }
            if let profile = coordinator.household.profile {
                let vm = PantryListViewModel(
                    household: profile,
                    repo: coordinator.pantryItemRepository,
                    entitlements: entitlements,
                )
                vm.load()
                viewModel = vm
            } else {
                initError = "Couldn't load your pantry. Please try again."
                Logger.ui.error("PantryListView: coordinator.household.profile unexpectedly nil")
            }
        }
    }

    @ViewBuilder
    private func listBody(vm: PantryListViewModel) -> some View {
        if vm.items.isEmpty {
            emptyState
        } else {
            populatedList(vm: vm)
        }
    }

    private func populatedList(vm: PantryListViewModel) -> some View {
        @Bindable var bindable = vm
        return VStack(spacing: 0) {
            // SCA-99 / ADR 0035: tier-downgrade reconciliation banner.
            // Surfaces above the header when EntitlementService has a
            // pending banner from a Premium/Pro → Free or Pro → Premium
            // hydrate that soft-archived `.remembered` rows to
            // `.ephemeral`. Dismissed manually OR auto-dropped after
            // 7 days via `RootView`'s scenePhase .active hook.
            if let banner = entitlements.pantryReconciliationBanner {
                reconciliationBanner(banner)
            }
            // Header strip — total active (non-deleted) items in the
            // pantry. We previously displayed `vm.rememberedCount`
            // against the standing-pantry cap (e.g. "2 of 1,000 saved")
            // which lied to the user when most rows were `.ephemeral`
            // TODAY items: 6 visible rows + "2 saved" was indistinguish-
            // able from a bug (SCA-20). The cap is still enforced at
            // insert path via `PantryItemRepository.insertManual`'s
            // `usedRemembered`/`cap` plumbing — surfacing it in the
            // header is informational at best and misleading at worst.
            // `vm.items` is repository-filtered to `deletedAt == nil`,
            // so `count` is honest.
            HStack(alignment: .firstTextBaseline) {
                Text("\(vm.items.count)")
                    .stirFont(.displayMd)
                    .foregroundStyle(Color.Stir.ink900)
                Text(vm.items.count == 1 ? "item" : "items")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.top, CGFloat.Stir.space3)
            .padding(.bottom, CGFloat.Stir.space2)

            List {
                ForEach(vm.filteredItems, id: \.objectID) { item in
                    PantryRow(item: item)
                        .listRowBackground(Color.Stir.paper100)
                        // SCA-53: pull the row separator's leading edge
                        // to 0 so the hairline reaches the cell's left
                        // edge. SwiftUI's default aligns separators to
                        // the first text-baseline content of the row,
                        // which lands AFTER PantryRow's 28pt camera-
                        // icon column — visible as separators that
                        // start mid-row. Setting the alignment guide
                        // to 0 forces full-width.
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .contentShape(Rectangle())
                        .onTapGesture { editingItem = item }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                vm.deleteItem(item)
                            } label: {
                                // Label's `icon:` slot routes through
                                // Image.Stir.delete rather than systemImage
                                // shorthand — keeps the no-raw-Image rule.
                                Label {
                                    Text("Remove")
                                } icon: {
                                    Image.Stir.delete
                                }
                            }
                            // ember700 mirrors SavedMealsView swipe
                            // convention — destructive intent in the
                            // warm palette without the system .red pop,
                            // keeps the Settings → Manage pantry surface
                            // continuous with the Saved tab.
                            .tint(Color.Stir.ember700)
                        }
                }

                // Delete-all footer. Lives inside the List as its own
                // Section so it scrolls with the content (user must
                // reach the end to find it — discoverable but not
                // accident-prone). Confirmation dialog at the view
                // root provides the destructive-action safety net per
                // the global "executing actions with care" guidance.
                // Hidden when the search filter narrows results so
                // the user isn't tempted to clear the pantry while
                // looking at a subset.
                if vm.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        Button(role: .destructive) {
                            showingDeleteAllConfirmation = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("Delete all items")
                                    .stirFont(.bodyMd)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.Stir.ember700)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .listRowBackground(Color.Stir.paper100)
                        // Same SCA-53 alignment fix as the data rows so
                        // the trailing footer separator (above the
                        // button) also reaches the leading edge.
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .accessibilityLabel("Delete all items from pantry")
                        .accessibilityHint("Removes every pantry item. Confirmation required.")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.Stir.paper50)
            // SCA-54: searchable hoisted to the outer Group at screen
            // scope; no `.searchable` modifier remains here. Keeping
            // the comment so a future reader doesn't accidentally
            // re-attach it to the inner List.
        }
        .background(Color.Stir.paper50)
        // Destructive bulk-delete confirmation. Lives at the
        // populatedList root (not on the button itself) so the dialog
        // stays attached even if the button scrolls out of view between
        // tap and confirm. The title reads the item count at present
        // time; the actual delete walks the live set via softDeleteAll.
        // Cancel is the default — the delete fires only on the explicit
        // destructive tap.
        .confirmationDialog(
            vm.items.count == 1 ? "Delete this item?" : "Delete all \(vm.items.count) items?",
            isPresented: $showingDeleteAllConfirmation,
            titleVisibility: .visible,
        ) {
            Button("Delete all items", role: .destructive) {
                vm.deleteAllItems()
            }
        } message: {
            Text("This removes every item from your pantry. You can't undo this in the app, but scanned items can be re-added.")
        }
        // Edit sheet stays here (rather than hoisted to outer Group)
        // because it's `.sheet(item:)` driven by a row tap and only
        // makes sense when the populated list is on screen. The
        // tombstone race is handled by the sheet itself observing
        // `item.deletedAt` and calling onExternallyRemoved.
        .sheet(item: $editingItem) { item in
            PantryEditSheet(
                item: item,
                onSave: { name, amount, state in
                    switch vm.editItem(item, displayName: name, amountText: amount, memoryState: state) {
                    case .saved:
                        editingItem = nil
                    case .capReached:
                        editingItem = nil
                        coordinator.presentPaywall(.pantryCapReached)
                    case .failed:
                        break
                    }
                },
                onDelete: {
                    vm.deleteItem(item)
                    editingItem = nil
                },
                onCancel: { editingItem = nil },
                onExternallyRemoved: {
                    vm.surfaceExternallyRemoved()
                },
            )
        }
    }

    /// SCA-99 / ADR 0035: non-blocking banner copy. Single tap on
    /// "Dismiss" clears the slot + persisted UserDefaults backing so
    /// the same downgrade event won't re-fire on the next foreground.
    private func reconciliationBanner(_ banner: EntitlementService.ReconciliationBanner) -> some View {
        HStack(alignment: .top, spacing: CGFloat.Stir.space2) {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
                Text("Your \(banner.archivedCount) oldest pantry \(banner.archivedCount == 1 ? "item is" : "items are") now temporary.")
                    .stirFont(.bodyMd)
                    .foregroundStyle(Color.Stir.ink900)
                Text("Re-upgrade to Premium to make them permanent again.")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
            }
            Spacer(minLength: CGFloat.Stir.space2)
            Button {
                entitlements.acknowledgeReconciliationBanner()
            } label: {
                Text("Dismiss")
                    .stirFont(.labelMd)
                    .foregroundStyle(Color.Stir.ember600)
            }
            .accessibilityLabel("Dismiss pantry reconciliation banner")
        }
        .padding(.horizontal, CGFloat.Stir.screenMargin)
        .padding(.vertical, CGFloat.Stir.space3)
        .background(Color.Stir.ember100)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: CGFloat.Stir.space3) {
            Spacer(minLength: CGFloat.Stir.space7)
            Image.Stir.pantry
                .font(.system(size: CGFloat.Stir.iconLg, weight: .regular))
                .foregroundStyle(Color.Stir.ember600)
                .frame(width: CGFloat.Stir.iconHero, height: CGFloat.Stir.iconHero)
                .background(
                    RoundedRectangle(cornerRadius: CGFloat.Stir.radiusHero, style: .continuous)
                        .fill(Color.Stir.ember100),
                )
            Text("Your pantry is empty.")
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.ink900)
                .multilineTextAlignment(.center)
            Text("Scan your fridge or pantry to populate this list, or add an item manually below.")
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink500)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CGFloat.Stir.space4)
            PrimaryButton(title: "Add an item") {
                showingAddSheet = true
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.top, CGFloat.Stir.space3)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, CGFloat.Stir.screenMargin)
        .background(Color.Stir.paper50)
    }
}

// PantryItem inherits `Identifiable` from `NSManagedObject` (iOS 13+),
// keyed on `objectID`. We don't add a conformance explicitly because
// the entity's `@NSManaged var id: UUID?` would collide with any
// `var id: NSManagedObjectID` we tried to declare. Sheet(item:)
// happily uses the inherited objectID-based identity.

/// Folds the error-toast + tombstone-toast wiring out of the outer
/// `body` so the expression stays under SwiftUI's typecheck ceiling.
/// Subscribes to `vm.errorEvent` (UUID-stamped, so string-equal
/// errors re-fire) and `vm.externallyRemovedItemEvent` (CloudKit
/// tombstone race), routing both through a single `.stirToast`.
private struct PantryToastModifier: ViewModifier {
    let viewModel: PantryListViewModel?
    @Binding var errorToast: StirToastPayload?
    @Binding var editingItem: PantryItem?

    func body(content: Content) -> some View {
        content
            .onChange(of: viewModel?.errorEvent) { _, newEvent in
                guard newEvent != nil, let message = viewModel?.errorMessage else { return }
                errorToast = StirToastPayload(id: UUID(), message: message, kind: .failed)
            }
            .onChange(of: viewModel?.externallyRemovedItemEvent) { _, newEvent in
                guard newEvent != nil else { return }
                editingItem = nil
                errorToast = StirToastPayload(
                    id: UUID(),
                    message: "This item was removed on another device.",
                    kind: .info,
                )
            }
            .stirToast($errorToast)
    }
}
