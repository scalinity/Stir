// PantryListViewModel
//
// Drives `PantryListView`. Loads PantryItem rows for the active
// household, exposes a filtered view over a typeahead `searchText`,
// and brokers manual-add / edit / delete through PantryItemRepository.
//
// Quota enforcement (Free 25 / Premium 250 / Pro 1000 remembered
// items per CLAUDE.md) is checked client-side via
// `repo.countRemembered(for:)` on every add — over-cap surfaces a
// `PaywallTrigger.pantryCapReached` paywall instead of writing.

import Foundation
import Observation
import OSLog

/// Outcome of `PantryListViewModel.addItem`. Distinguishes cap-reached
/// (paywall) from a transient repository failure (toast). The view
/// previously collapsed both into a `Bool` and routed the failure
/// case to the Premium paywall — wrong upsell for a paid user when a
/// Core Data save flaked.
enum PantryAddResult: Equatable {
    /// Item was inserted (or upserted onto a name-matching row).
    case added
    /// Standing-pantry cap was reached. View should present the
    /// `pantryCapReached` paywall.
    case capReached
    /// Repository or count check failed. View should surface
    /// `errorMessage` as a toast — DO NOT present the paywall.
    case failed
}

@MainActor
@Observable
final class PantryListViewModel {
    /// Underlying NSManagedObjects so SwiftUI rows can `@ObservedObject`
    /// for live KVO redraws on edit. See PantryItemRepository.fetchAll
    /// commentary for why value-type projection is overkill here.
    private(set) var items: [PantryItem] = []

    /// Bound from the search bar in PantryListView. Filtering runs on
    /// every set; we don't memoize because the in-memory list is small
    /// (≤1000 entries, capped by the Pro tier).
    var searchText: String = ""

    var filteredItems: [PantryItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { ($0.displayName ?? "").lowercased().contains(q) }
    }

    /// Set when the most recent insert/update/delete failed. Bound to a
    /// toast at the view layer so the user gets an actionable message
    /// rather than a silent no-op.
    var errorMessage: String?

    private let household: HouseholdProfile
    private let repo: PantryItemRepository
    private let entitlements: EntitlementService

    init(
        household: HouseholdProfile,
        repo: PantryItemRepository,
        entitlements: EntitlementService,
    ) {
        self.household = household
        self.repo = repo
        self.entitlements = entitlements
    }

    /// Hydrate `items` from Core Data. Called from `.task { }` on
    /// PantryListView's appearance and after every mutation.
    func load() {
        do {
            items = try repo.fetchAll(for: household)
        } catch {
            Logger.coreData.error("PantryListViewModel load failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn't load your pantry. Pull to retry."
        }
    }

    /// Manual-add path. Returns a typed `PantryAddResult`: `.capReached`
    /// routes to the paywall, `.failed` surfaces `errorMessage` via a
    /// toast, `.added` is success. The VM doesn't own paywall
    /// presentation — the view layer reads the result and dispatches.
    @discardableResult
    func addItem(
        displayName: String,
        amountText: String?,
        memoryState: PantryItem.MemoryState = .remembered,
    ) -> PantryAddResult {
        // Standing pantry items count against the cap; ephemeral
        // (today-only) items do not.
        if memoryState == .remembered {
            do {
                let used = try repo.countRemembered(for: household)
                let cap = entitlements.rememberedPantryCap
                guard used < cap else {
                    return .capReached
                }
            } catch {
                Logger.coreData.warning("countRemembered failed; allowing add: \(error.localizedDescription, privacy: .public)")
                // Fail-open on count failure — better to over-store than
                // to dead-end the user behind a phantom quota error.
            }
        }
        do {
            _ = try repo.insertManual(
                displayName: displayName,
                amountText: amountText,
                memoryState: memoryState,
                on: household,
            )
            load()
            return .added
        } catch {
            Logger.coreData.error("addItem failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn't add this item. Try again."
            return .failed
        }
    }

    /// Edit-sheet commit. Refreshes the list so reorder by lastSeenAt
    /// (technically unchanged here — only updatedAt moves) is honored.
    @discardableResult
    func editItem(
        _ item: PantryItem,
        displayName: String,
        amountText: String?,
        memoryState: PantryItem.MemoryState,
    ) -> Bool {
        do {
            try repo.update(
                item,
                displayName: displayName,
                amountText: amountText,
                memoryState: memoryState,
            )
            load()
            return true
        } catch {
            Logger.coreData.error("editItem failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn't save this change. Try again."
            return false
        }
    }

    /// Swipe-to-delete from PantryListView. Soft-delete preserves
    /// CloudKit replication of the tombstone (matches the Saved
    /// favorites delete pattern).
    @discardableResult
    func deleteItem(_ item: PantryItem) -> Bool {
        do {
            try repo.softDelete(item)
            load()
            return true
        } catch {
            Logger.coreData.error("deleteItem failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn't remove this item. Try again."
            return false
        }
    }
}
