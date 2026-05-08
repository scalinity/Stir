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
                // accident-prone). Confirmation sheet at the view
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
            // Tab-bar bottom-clearance compensation. StirCustomTabBar
            // uses `padding(.bottom, -.space3Half)` (−14pt) to encroach
            // into the home-indicator inset. The List's auto safeArea
            // reservation already covers the bar's measured frame —
            // `contentMargins(.scrollContent)` adds ON TOP of that, so
            // it only needs to cover the negative-padding extent + a
            // small visual buffer (≈14pt + 10pt = 24pt = `.space5`).
            // SCA-20 originally copied Tonight's 64pt value, but
            // Tonight uses `.padding(.bottom)` INSIDE a ScrollView's
            // VStack — that primitive composes with safeArea differently
            // and needs the larger number. SCA-50 right-sizes Pantry to
            // its actual primitive, removing the visible "extra-tall
            // tab bar" gap. Coupled with the bar's chrome — change one,
            // recheck the other.
            .contentMargins(.bottom, CGFloat.Stir.space5, for: .scrollContent)
            // SCA-54: searchable hoisted to the outer Group at screen
            // scope; no `.searchable` modifier remains here. Keeping
            // the comment so a future reader doesn't accidentally
            // re-attach it to the inner List.
        }
        .background(Color.Stir.paper50)
        // Themed destructive bulk-delete confirmation. Lives at the
        // populatedList root (not on the button itself) so the sheet
        // stays attached even if the button scrolls out of view between
        // tap and confirm. Item count is captured at present-time so a
        // CloudKit-merge that lands while the sheet is up doesn't lie
        // about what's being deleted — the sheet text reads against the
        // snapshot at tap; the actual delete walks the live count via
        // softDeleteAll.
        //
        // SCA-50: was `.confirmationDialog(...)` which renders as an
        // iOS-26 glass popover anchored to the trigger — looked
        // off-theme on the surrounding Stir surface. Custom sheet uses
        // the same backstop (cancel-default focus, primary CTA only on
        // explicit destructive tap) while honoring the design system.
        .sheet(isPresented: $showingDeleteAllConfirmation) {
            PantryDeleteAllConfirmationSheet(
                itemCount: vm.items.count,
                onConfirm: {
                    showingDeleteAllConfirmation = false
                    vm.deleteAllItems()
                },
            )
            .presentationDetents([.height(360)])
            .presentationCornerRadius(CGFloat.Stir.radiusLg)
            .presentationBackground(Color.Stir.paper50)
            .presentationDragIndicator(.visible)
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

// MARK: - PantryDeleteAllConfirmationSheet

/// Themed confirmation modal for bulk-delete on the pantry list (SCA-50).
/// Replaces the system `.confirmationDialog` whose iOS-26 glass-popover
/// styling clashed with the rest of the Stir surface. Lives in the same
/// file as its only caller — promoting to `DesignSystem/Components/`
/// only makes sense once a second destructive flow needs the same shape
/// (favorites bulk-clear is the next plausible candidate).
private struct PantryDeleteAllConfirmationSheet: View {
    let itemCount: Int
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // ScrollView so Dynamic-Type at AX text sizes scrolls within the
        // locked `.height(360)` detent instead of clipping the destructive
        // CTA. At default text sizes the content fits and the ScrollView
        // is invisible — at AX3+ users can scroll the title/body to
        // surface the buttons. Cheap insurance for the explicit detent.
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space4) {
                VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
                    Text(titleText)
                        .stirFont(.displaySm)
                        .foregroundStyle(Color.Stir.ink900)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("This removes every item from your pantry. You can't undo this in the app, but scanned items can be re-added.")
                        .stirFont(.bodyMd)
                        .foregroundStyle(Color.Stir.ink500)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: CGFloat.Stir.space3)

                VStack(spacing: CGFloat.Stir.space3) {
                    // Destructive CTA. Mirrors PrimaryButton's geometry
                    // (full-width, 52pt tall, radiusMd) but swaps the
                    // ember600 fill for crimson600 — the standing
                    // "destructive primary action" treatment the design
                    // system already exposes via Color.Stir.crimson600
                    // (== .danger). Built inline rather than parameterizing
                    // PrimaryButton so the change stays scoped to SCA-50.
                    Button(action: onConfirm) {
                        Text("Delete all items")
                            .stirFont(.labelLg)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.Stir.paper50)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .frame(height: 52)
                            .background(
                                RoundedRectangle(
                                    cornerRadius: CGFloat.Stir.radiusMd,
                                    style: .continuous,
                                )
                                .fill(Color.Stir.crimson600),
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityText)
                    .accessibilityHint("Removes every pantry item. This cannot be undone in the app.")

                    // Cancel dismisses via @Environment(\.dismiss) so the
                    // explicit-button path and the swipe-down/backdrop-tap
                    // gesture-dismiss path resolve through the same hook —
                    // a future telemetry addition (e.g.
                    // pantry_delete_all_cancelled) only needs one
                    // subscription point. onConfirm stays as a parent
                    // closure because the destructive intent must NOT
                    // fire on gesture-dismiss.
                    SecondaryButton(title: "Cancel") {
                        dismiss()
                    }
                }
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.top, CGFloat.Stir.space5)
            .padding(.bottom, CGFloat.Stir.space4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
        .background(Color.Stir.paper50)
    }

    /// Header copy with proper grammar at the singular case. Stir's
    /// English-only launch (spec §11) doesn't excuse "Delete all 1
    /// items?" — branching on itemCount is one ternary and removes
    /// the user-visible grammar slip.
    private var titleText: String {
        itemCount == 1 ? "Delete this item?" : "Delete all \(itemCount) items?"
    }

    private var accessibilityText: String {
        itemCount == 1 ? "Delete this pantry item" : "Delete all \(itemCount) pantry items"
    }
}

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
