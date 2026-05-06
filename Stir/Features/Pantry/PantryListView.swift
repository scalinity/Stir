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
    /// `viewModel?.items.isEmpty == false`). Drives both the
    /// `.coachMarks(steps:)` variant pick and the `.id(...)` re-mount
    /// trigger that fixes the stale-variant bug across pantry
    /// transitions.
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
        .navigationTitle("Pantry")
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
                // SCA-14 — toolbar + is the third step of the in-list
                // tour (`PantryCoachMarks.inListTour.populated_add`).
                // The 44pt min-tap-target frame above doubles as the
                // spotlight anchor frame, so the halo covers the
                // visible chrome even though the SF Symbol is smaller.
                //
                // The anchor frame is registered while `viewModel == nil`
                // (the disabled cold-launch state) too, but the
                // `shouldPresent: viewModel?.didCompleteInitialLoad`
                // gate above defers the tour until the first load
                // completes — by which point the button is enabled.
                // No race window in practice.
                .coachMarkAnchor(.pantryAddButton)
            }
        }
        .toolbarBackground(Color.Stir.paper50, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        // SCA-14 — in-list pantry walkthrough. Variant chosen on
        // whether the pantry has rows: the populated 5-step tour
        // anchors on the header strip, toolbar +, first row, and
        // source glyph. The 3-step empty variant collapses to welcome
        // / context / empty-state Add CTA so the spotlight never
        // targets a missing row. Same `pantryInListTour` key backs
        // both — completion is one bit per user, not per variant.
        // Replay via Settings → Replay tutorials cycles whichever
        // variant matches the current pantry state.
        //
        // **Stale-variant fix (review-5 SCA-14 Critical #1):** the
        // presenter modifier captures `steps` at controller-init time;
        // a body re-render with a different `steps` array doesn't
        // reach the controller. Forcing the modifier to fully re-mount
        // via `.id(pantryHasItems)` constructs a fresh controller with
        // the correct variant whenever the pantry transitions
        // empty↔populated mid-tour. The old controller's `suspend()`
        // fires on its `.onDisappear`, leaving the durable completion
        // flag untouched (lifecycle invariant) so the new variant
        // re-arms naturally.
        .coachMarks(
            key: .pantryInListTour,
            steps: pantryHasItems
                ? PantryCoachMarks.inListTour
                : PantryCoachMarks.inListTourEmpty,
            shouldPresent: viewModel?.didCompleteInitialLoad == true,
        )
        .id(pantryHasItems)
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
            // Header strip — REMEMBERED count vs cap. The previous
            // `vm.items.count` lied: a user with 5 ephemeral + 22
            // remembered would see "27 of 25 saved" because items
            // includes ephemeral rows that don't count against the
            // cap (review C2). `rememberedCount` mirrors the
            // repository's `countRemembered` predicate.
            HStack(alignment: .firstTextBaseline) {
                Text("\(vm.rememberedCount)")
                    .stirFont(.displayMd)
                    .foregroundStyle(Color.Stir.ink900)
                Text("of \(entitlements.rememberedPantryCap) saved")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
                    // Dynamic Type protection: at AX3+ on iPhone SE
                    // (320pt content), the displayMd count + bodySm
                    // trailing text would clip without scaling
                    // (review W12).
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.top, CGFloat.Stir.space3)
            .padding(.bottom, CGFloat.Stir.space2)
            // SCA-14 — the cap-headroom strip is step 2 of the in-list
            // tour. Tagged at the outer HStack so the spotlight covers
            // the count + "of N saved" together.
            .coachMarkAnchor(.pantryHeaderStrip)

            // Hoist the first-row identity once per body re-eval so
            // each ForEach iteration is one optional-equality check
            // rather than the per-row `Array(...enumerated())` tuple
            // allocation that landed initially. The list re-renders on
            // every search keystroke (typeahead) and every Core Data
            // mutation; for pantries near the Pro 1000-item cap, the
            // allocation cost was non-trivial.
            let firstItemID = vm.filteredItems.first?.objectID
            List {
                ForEach(vm.filteredItems, id: \.objectID) { item in
                    PantryRow(item: item, isFirstRow: item.objectID == firstItemID)
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
                        // SCA-14 — only the first row registers as the
                        // tour's row-tap/swipe anchor. Optional-overload
                        // means the others write nothing to the
                        // anchor-frames map.
                        .coachMarkAnchor(item.objectID == firstItemID ? .pantryFirstRow : nil)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.Stir.paper50)
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
            // SCA-14 — terminal anchor for `inListTourEmpty` so the
            // tour has a real CTA to spotlight when there are no rows.
            .coachMarkAnchor(.pantryListEmptyAdd)
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
