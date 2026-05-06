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
    let coordinator: RootCoordinator

    @Environment(EntitlementService.self) private var entitlements
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: PantryListViewModel?
    @State private var showingAddSheet = false
    @State private var editingItem: PantryItem?
    @State private var initError: String?
    @State private var errorToast: StirToastPayload?

    /// Hoisted as a positive boolean (vs the triple-negative
    /// `viewModel?.items.isEmpty == false`). Picks the in-list
    /// pantry tutorial variant — populated vs empty — so the right
    /// `PantryInListTutorial` mounts via the matching TutorialKey.
    private var pantryHasItems: Bool {
        viewModel?.items.isEmpty == false
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Pantry")
                    .stirFont(.displaySm)
                    .foregroundStyle(Color.Stir.textPrimary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image.Stir.plus
                        .foregroundStyle(Color.Stir.ember600)
                        // HIG floor: SF Symbol intrinsic ~22×22pt; toolbar
                        // hit area is borderline without an explicit minimum
                        // (review W14).
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(viewModel == nil)
                .accessibilityLabel("Add item")
            }
        }
        .toolbarBackground(Color.Stir.paper50, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        // SCA-19 — full-screen in-list Pantry walkthrough. Variant
        // chosen on whether the pantry has rows; we mount one
        // `.tutorial(...)` modifier per variant so each TutorialKey
        // owns its own UserDefaults flag and replay gating. Distinct-
        // key design (SCA-17 C4) is preserved — completing the
        // empty-pantry tour does not silently burn the populated-tour
        // bit, so the natural new-user trajectory (empty → first
        // add → populated) gets BOTH tours over its lifetime. Search-
        // empty gating prevents firing the populated tour while the
        // user is filtering with a query that hides every row.
        .tutorial(
            key: .pantryInListTour,
            content: { PantryInListTutorial(variant: .populated) },
            shouldPresent: pantryHasItems
                && viewModel?.didCompleteInitialLoad == true
                && (viewModel?.searchText.isEmpty ?? true),
        )
        .tutorial(
            key: .pantryInListTourEmpty,
            content: { PantryInListTutorial(variant: .empty) },
            shouldPresent: !pantryHasItems
                && viewModel?.didCompleteInitialLoad == true
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
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.Stir.paper50)
            // StirCustomTabBar uses `padding(.bottom, -.space3Half)`
            // (-14pt) to encroach into the home-indicator inset, so
            // `safeAreaInset` reserves 14pt LESS than the bar's visual
            // extent. Without this margin, the last row visibly clips
            // under the bar (SCA-20). Coupled with the bar's negative
            // bottom padding — change one, recheck the other.
            .contentMargins(.bottom, CGFloat.Stir.space3Half, for: .scrollContent)
            .searchable(text: $bindable.searchText, prompt: "Search pantry")
        }
        .background(Color.Stir.paper50)
        // Edit sheet stays here (rather than hoisted to outer Group)
        // because it's `.sheet(item:)` driven by a row tap and only
        // makes sense when the populated list is on screen. The
        // tombstone race is handled by the sheet itself observing
        // `item.deletedAt` and calling onExternallyRemoved.
        .sheet(item: $editingItem) { item in
            PantryEditSheet(
                item: item,
                onSave: { name, amount, state in
                    vm.editItem(item, displayName: name, amountText: amount, memoryState: state)
                    editingItem = nil
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

    private var emptyState: some View {
        VStack(spacing: CGFloat.Stir.space3) {
            Spacer(minLength: CGFloat.Stir.space7)
            Image.Stir.pantry
                .font(.system(size: CGFloat.Stir.iconLg, weight: .regular))
                .foregroundStyle(Color.Stir.ember600)
                .frame(width: 80, height: 80)  // justification: 80pt hero icon tile, matches TonightHomeView empty-state square (sub-token escape hatch)
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
