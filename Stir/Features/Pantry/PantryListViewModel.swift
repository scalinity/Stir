// PantryListViewModel
//
// Drives `PantryListView`. Loads PantryItem rows for the active
// household, exposes a filtered view over a typeahead `searchText`,
// and brokers manual-add / edit / delete through PantryItemRepository.
//
// Quota enforcement: cap source-of-truth lives on `Tier` (see
// `Tier.rememberedPantryCap`); `EntitlementService.rememberedPantryCap`
// routes through `effectiveTier`. The actual at-cap rejection happens
// inside `PantryItemRepository.insertManual` so a re-typed existing
// remembered name at cap upserts (no row added) instead of being
// wrongly routed to the paywall (review C4).

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

    /// Flips true after the first `load()` completes (success OR
    /// error). Used by the SCA-14 in-list coach-mark gate to defer
    /// presentation until at least one fetch has landed — without
    /// this, the empty-pantry tour variant could fire over a
    /// populated screen during the brief window between view appear
    /// and the first batch of items rendering.
    private(set) var didCompleteInitialLoad: Bool = false

    /// Bound from the search bar in PantryListView. Filtering runs on
    /// every set; we don't memoize because the in-memory list is small
    /// (≤1000 entries, capped by the Pro tier).
    var searchText: String = ""

    var filteredItems: [PantryItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { ($0.displayName ?? "").lowercased().contains(q) }
    }

    /// Live count of items that count against the standing pantry cap
    /// — non-deleted, non-expired `.remembered` rows. Mirrors
    /// `PantryItemRepository.countRemembered`'s predicate but operates
    /// on the in-memory `items` array so the header strip can re-render
    /// inexpensively after every mutation. The header used to read
    /// `vm.items.count` (which includes ephemeral / expired / unknown)
    /// against `cap` and visibly lied — e.g. "27 of 25 saved" with 5
    /// ephemeral + 22 remembered (review C2).
    var rememberedCount: Int {
        items.filter { item in
            item.deletedAt == nil
                && item.typedMemoryState == .remembered
                && !item.isExpired
        }.count
    }

    /// Set when the most recent insert/update/delete failed. Bound to a
    /// toast at the view layer (see `PantryListView.errorToast` binding).
    /// Pair with `errorEvent` so the view can re-fire a toast for the
    /// same string without StringEquality dedupe via `.onChange`.
    var errorMessage: String?

    /// Monotonic UUID stamped on every error transition. The view binds
    /// this to a `.onChange` so duplicate errors (load-fail then add-
    /// fail with the same generic copy) still surface as fresh toasts.
    /// Reset to `nil` on every successful mutation entry so the toast
    /// surface is single-shot per failure.
    private(set) var errorEvent: UUID?

    /// Set when `editingItem` is observed to have its `deletedAt`
    /// flipped (CloudKit-tombstone race). View dismisses the edit
    /// sheet and surfaces a typed toast. Cleared by the view after
    /// presentation. Review W3.
    var externallyRemovedItemEvent: UUID?

    private let household: HouseholdProfile
    private let repo: PantryItemRepository
    private let entitlements: EntitlementService
    private let sentry: any SentryReporting

    init(
        household: HouseholdProfile,
        repo: PantryItemRepository,
        entitlements: EntitlementService,
        sentry: any SentryReporting = SentryReporter.shared,
    ) {
        self.household = household
        self.repo = repo
        self.entitlements = entitlements
        self.sentry = sentry
    }

    /// Hydrate `items` from Core Data. Called from `.task { }` on
    /// PantryListView's appearance and after every mutation. Flips
    /// `didCompleteInitialLoad` true on first call regardless of
    /// outcome — the SCA-14 coach-mark gate uses this to defer tour
    /// presentation until we have ground truth about the pantry's
    /// emptiness, so the empty-variant tour doesn't briefly fire
    /// over a populated screen during a slow first fetch.
    func load() {
        clearError()
        defer { didCompleteInitialLoad = true }
        do {
            items = try repo.fetchAll(for: household)
        } catch {
            Logger.coreData.error(
                "PantryListViewModel load failed: \(error.localizedDescription, privacy: .private)",
            )
            surfaceError("Couldn't load your pantry. Try again.")
        }
    }

    /// Manual-add path. Returns a typed `PantryAddResult`: `.capReached`
    /// routes to the paywall, `.failed` surfaces `errorMessage` via a
    /// toast (and the view keeps the AddSheet open so user input isn't
    /// lost — review S11), `.added` is success.
    ///
    /// Cap enforcement lives in the repository (see
    /// `PantryItemRepository.insertManual`'s `usedRemembered`/`cap` pair)
    /// so a re-typed existing remembered name at cap upserts instead
    /// of being paywalled — review C4. The VM still surfaces
    /// `(used, cap)` from EntitlementService at the call site.
    @discardableResult
    func addItem(
        displayName: String,
        amountText: String?,
        memoryState: PantryItem.MemoryState = .remembered,
    ) -> PantryAddResult {
        clearError()

        var usedRemembered: Int? = nil
        if memoryState == .remembered {
            do {
                usedRemembered = try repo.countRemembered(for: household)
            } catch {
                // Fail-open on count failure — better to over-store
                // than to dead-end the user behind a phantom quota
                // error. Surface as a Sentry breadcrumb so a systemic
                // failure becomes observable in production.
                Logger.coreData.warning(
                    "countRemembered failed; allowing add: \(error.localizedDescription, privacy: .private)",
                )
                sentry.breadcrumb(
                    category: "pantry",
                    message: "countRemembered_failed_open",
                    data: ["error_kind": String(describing: type(of: error))],
                )
            }
        }
        let cap = entitlements.rememberedPantryCap

        do {
            let outcome = try repo.insertManual(
                displayName: displayName,
                amountText: amountText,
                memoryState: memoryState,
                on: household,
                usedRemembered: usedRemembered,
                cap: cap,
            )
            switch outcome {
            case .inserted, .upserted:
                load()
                return .added
            case .capReached:
                return .capReached
            }
        } catch {
            Logger.coreData.error(
                "addItem failed: \(error.localizedDescription, privacy: .private)",
            )
            surfaceError("Couldn't add this item. Try again.")
            return .failed
        }
    }

    /// Edit-sheet commit. Calls `load()` after success so any new
    /// fields the row's `@ObservedObject` hadn't propagated synchronously
    /// (e.g. memoryState changes affecting `rememberedCount` derivation)
    /// surface immediately. `lastSeenAt` is intentionally NOT bumped on
    /// edit — an edit shouldn't re-rank a row to the top of the
    /// recently-seen list.
    ///
    /// `memoryState == nil` means "preserve the row's existing
    /// memoryState" — sent by `PantryEditSheet` when the user didn't
    /// touch the segmented picker. This avoids silently flipping
    /// `.expired`/`.unknown` rows to `.remembered` on an untouched
    /// save (review C3).
    @discardableResult
    func editItem(
        _ item: PantryItem,
        displayName: String,
        amountText: String?,
        memoryState: PantryItem.MemoryState?,
    ) -> Bool {
        clearError()
        let stateToPersist = memoryState ?? item.typedMemoryState
        do {
            try repo.update(
                item,
                displayName: displayName,
                amountText: amountText,
                memoryState: stateToPersist,
            )
            load()
            return true
        } catch {
            Logger.coreData.error(
                "editItem failed: \(error.localizedDescription, privacy: .private)",
            )
            surfaceError("Couldn't save this change. Try again.")
            return false
        }
    }

    /// Swipe-to-delete from PantryListView. Soft-delete preserves
    /// CloudKit replication of the tombstone (matches the Saved
    /// favorites delete pattern).
    @discardableResult
    func deleteItem(_ item: PantryItem) -> Bool {
        clearError()
        do {
            try repo.softDelete(item)
            load()
            return true
        } catch {
            Logger.coreData.error(
                "deleteItem failed: \(error.localizedDescription, privacy: .private)",
            )
            surfaceError("Couldn't remove this item. Try again.")
            return false
        }
    }

    /// View invokes this when it observes `editingItem.deletedAt != nil`
    /// while the edit sheet is presented (CloudKit-tombstone race).
    /// Triggers a typed toast separate from the generic error message.
    func surfaceExternallyRemoved() {
        externallyRemovedItemEvent = UUID()
    }

    // MARK: - Error event helpers

    private func surfaceError(_ message: String) {
        errorMessage = message
        errorEvent = UUID()
    }

    /// Reset error state at the head of every mutation so a stale
    /// failure copy doesn't toast on a subsequent successful render.
    private func clearError() {
        errorMessage = nil
    }
}
