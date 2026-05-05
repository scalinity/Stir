// PantryListView
//
// Settings → "Manage pantry" destination. Lists the household's
// PantryItems (NSManagedObject-bound rows for live KVO redraws via
// PantryRow) with swipe-to-delete + tap-to-edit. Top-of-list shows
// current count vs cap so users see headroom; tapping the toolbar
// "+" opens PantryAddSheet, with quota enforcement routing to the
// paywall when over-cap.
//
// Empty state mirrors TonightHomeView's first-use grammar (large
// ember-tinted icon tile + title + subtitle + primary CTA) but
// points at scan as the primary populate path with manual-add as
// the fallback. Reachable from Settings, so dismissal is the system
// back chevron.
//
// Coordinator is passed explicitly (not pulled from `@Environment`)
// because this screen brokers two coordinator surfaces — the pantry
// repository and `presentPaywall(_:)` — and the parameter form makes
// the dependency contract visible to callers (Settings entry-point
// in Task 10). Established pattern in Settings → HouseholdPreferences
// uses environment injection; this view's tighter coupling to
// coordinator-owned services made the parameter form clearer.

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

    var body: some View {
        Group {
            if let viewModel {
                listBody(vm: viewModel)
            } else if let initError {
                // Profile unavailable at task-time — Settings is reachable
                // pre-bootstrap on cold deeplink launches. Mirror the
                // HouseholdPreferencesView posture: ConfigurationErrorView
                // with a dismiss action so the user can back out.
                ConfigurationErrorView(message: initError, onRetry: { dismiss() })
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
            // Principal item renders the screen title in the Stir
            // display serif, matching SettingsRootView and Saved.
            // Default `navigationTitle` chrome falls back to SF Pro
            // and breaks cross-tab visual rhythm.
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
                }
                .accessibilityLabel("Add item")
            }
        }
        .toolbarBackground(Color.Stir.paper50, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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
            // Header strip — count + cap headroom. Reads "23 of 250
            // saved" so users see remaining room before the cap kicks
            // in. Cap is server-resolved per tier via EntitlementService.
            HStack(alignment: .firstTextBaseline) {
                Text("\(vm.items.count)")
                    .stirFont(.displayMd)
                    .foregroundStyle(Color.Stir.ink900)
                Text("of \(entitlements.rememberedPantryCap) saved")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
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
                                // Label's `icon:` slot accepts an arbitrary
                                // View, so we route through Image.Stir.delete
                                // rather than the systemImage shorthand —
                                // keeps the no-raw-Image(systemName:) rule
                                // intact even inside swipeActions.
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
            .searchable(text: $bindable.searchText, prompt: "Search pantry")
        }
        .background(Color.Stir.paper50)
        .sheet(isPresented: $showingAddSheet) {
            PantryAddSheet(
                onSave: { name, amount, state in
                    let ok = vm.addItem(displayName: name, amountText: amount, memoryState: state)
                    showingAddSheet = false
                    if !ok {
                        coordinator.presentPaywall(.pantryCapReached)
                    }
                },
                onCancel: { showingAddSheet = false },
            )
        }
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
        .sheet(isPresented: $showingAddSheet) {
            PantryAddSheet(
                onSave: { name, amount, state in
                    if let vm = viewModel {
                        let ok = vm.addItem(displayName: name, amountText: amount, memoryState: state)
                        if !ok {
                            coordinator.presentPaywall(.pantryCapReached)
                        }
                    }
                    showingAddSheet = false
                },
                onCancel: { showingAddSheet = false },
            )
        }
    }
}

// PantryItem inherits `Identifiable` from `NSManagedObject` (iOS 13+),
// keyed on `objectID`. We don't add a conformance explicitly because
// the entity's `@NSManaged var id: UUID?` would collide with any
// `var id: NSManagedObjectID` we tried to declare. Sheet(item:)
// happily uses the inherited objectID-based identity.
