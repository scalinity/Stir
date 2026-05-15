// GroceryViewModel
//
// Drives the Grocery flow from "Add to grocery" → list preview →
// Reminders export. Three-stage machine:
//
//   1. .generating — calling /v1/ai/grocery-generate
//   2. .ready — items grouped by category, user can edit before export
//   3. .exported — Reminders export succeeded; status flipped to
//      `exported`, reminderListId + per-item reminderId persisted on
//      the GroceryItem rows
//
// Degraded path: Reminders denied → stage stays `.ready`, user can
// use the in-app list (toggle checkboxes, copy/share). GroceryList
// status stays `.draft`. Telemetry emits `destination: "in_app"` per
// spec §15.
//
// Invariants:
//   - GroceryList.status transitions exactly `draft → exported`
//     (spec §4.16). Never back to draft after export.
//   - Every GroceryItem row has `priority` populated (spec §4.17).
//     Defaults to `.normal` if backend omits.
//   - Dedupe by canonical_slug happens in GroceryRepository, not here.

import Foundation
import OSLog

@Observable
@MainActor
final class GroceryViewModel {
    enum Stage: Equatable {
        case generating
        case ready
        case exported
        case error(code: String, message: String)
    }

    private(set) var stage: Stage = .generating

    /// The persisted GroceryList (status = draft initially).
    private(set) var list: GroceryList?

    /// Items grouped by aisle, sorted per aisle convention (produce →
    /// meat → dairy → frozen → pantry → other).
    ///
    /// Memoized in `_groupedItems` and rebuilt only on `list` mutation
    /// (generate/replace/ingest) or an item being added/removed —
    /// toggling isChecked doesn't change grouping so keystroke-rate
    /// body re-evals stay O(1) instead of O(n) × GroceryCategory
    /// allCases (S7).
    private var _groupedItems: [(category: GroceryCategory, items: [GroceryItem])] = []
    private var _groupedItemsItemCount: Int = -1

    var groupedItems: [(category: GroceryCategory, items: [GroceryItem])] {
        let currentCount = list?.orderedItems.count ?? 0
        if currentCount == _groupedItemsItemCount { return _groupedItems }
        rebuildGroupedItems()
        return _groupedItems
    }

    private func rebuildGroupedItems() {
        let items = list?.orderedItems ?? []
        _groupedItemsItemCount = items.count
        if items.isEmpty {
            _groupedItems = []
            return
        }
        let byCategory = Dictionary(grouping: items, by: \.categoryEnum)
        _groupedItems = GroceryCategory.allCases
            .compactMap { cat in
                guard let items = byCategory[cat], !items.isEmpty else { return nil }
                return (category: cat, items: items)
            }
            .sorted { $0.category.aisleOrder < $1.category.aisleOrder }
    }

    var missingCount: Int { list?.orderedItems.count ?? 0 }

    /// Items the user has checked in the in-app list view. Mutating this
    /// persists via the repo on each toggle.
    func toggleChecked(_ item: GroceryItem) {
        do { try groceryRepo.toggleChecked(item) } catch {
            Logger.ui.warning("grocery toggle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    let recipePlan: RecipePlan
    let household: HouseholdProfile
    private let aiDispatch: AIDispatch
    private let groceryRepo: GroceryRepository
    private let reminders: GroceryRemindersService
    private let analytics: PostHogClient

    init(
        recipePlan: RecipePlan,
        household: HouseholdProfile,
        aiDispatch: AIDispatch,
        groceryRepo: GroceryRepository = GroceryRepository(controller: .shared),
        reminders: GroceryRemindersService = GroceryRemindersService(),
        analytics: PostHogClient = .shared,
    ) {
        self.recipePlan = recipePlan
        self.household = household
        self.aiDispatch = aiDispatch
        self.groceryRepo = groceryRepo
        self.reminders = reminders
        self.analytics = analytics
    }

    // MARK: - Generate

    /// Kick off the generate flow: call Edge Function with pantry
    /// snapshot, persist the draft list, transition to `.ready`.
    /// Idempotent — calling twice will produce two GroceryLists; caller
    /// gates on stage == .generating.
    func generate() async {
        guard stage == .generating else { return }
        guard household.id != nil else {
            stage = .error(code: "VAL-01", message: "Household missing id. Restart the app.")
            return
        }
        guard let recipePlanID = recipePlan.id else {
            stage = .error(code: "VAL-01", message: "Recipe plan missing id.")
            return
        }

        // Build request body: recipe ingredients + household's pantry
        // snapshot (so backend can diff).
        let recipeIngredients = (recipePlan.ingredients as? Set<RecipeIngredient>) ?? []
        let ingredientsNeeded = recipeIngredients
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { ing -> GroceryGenerateRequest.Ingredient? in
                guard let name = ing.displayName, !name.isEmpty else { return nil }
                return GroceryGenerateRequest.Ingredient(
                    displayName: name,
                    canonicalSlug: ing.canonicalIngredientSlug,
                    amountText: ing.amountText,
                )
            }
        // SCA-424 / SCA-431: consume the canonical pantry filter from
        // `HouseholdProfile.confirmedActivePantry()`. Same drift class
        // as the substitution sheet (soft-deleted + unconfirmed rows
        // leaking to the model); centralising prevents recurrence.
        let pantrySnapshot = household.confirmedActivePantry()
            .compactMap { item -> GroceryGenerateRequest.PantryItemLite? in
                guard let name = item.displayName, !name.isEmpty else { return nil }
                return GroceryGenerateRequest.PantryItemLite(
                    displayName: name,
                    canonicalSlug: item.canonicalIngredientSlug,
                )
            }

        let request = GroceryGenerateRequest(
            sourceID: recipePlanID,
            sourceType: .recipe,
            ingredientsNeeded: ingredientsNeeded,
            pantrySnapshot: pantrySnapshot,
            recipeTitle: recipePlan.title,
        )

        do {
            let response = try await aiDispatch.groceryGenerate(request: request)
            let listRow = try groceryRepo.createDraft(
                for: household,
                title: recipePlan.title ?? "Grocery",
                sourceCookingSessionID: nil,
            )
            let incoming = response.missingItems.map { item in
                GroceryRepository.IncomingItem(
                    displayName: item.displayName,
                    quantityText: item.amountText,
                    canonicalSlug: item.canonicalSlug,
                    category: GroceryCategory(rawValue: item.groceryCategory) ?? .other,
                    priority: GroceryItemPriority(rawValue: item.priority) ?? .normal,
                )
            }
            try groceryRepo.replaceItems(on: listRow, items: incoming)
            self.list = listRow
            self.stage = .ready
        } catch {
            Logger.ui.error("grocery generate failed: \(error.localizedDescription, privacy: .public)")
            stage = .error(code: "AI-01", message: "Couldn't build a grocery list right now. Try again in a moment.")
        }
    }

    // MARK: - Export

    /// Export to Reminders. On success: flips list → exported, emits
    /// `grocery_list_exported` with `destination=reminders`. On denied:
    /// emits `destination=in_app`, keeps `.draft`, surfaces a hint so
    /// the caller can route to Settings.
    func exportToReminders() async -> Bool {
        guard let list else { return false }
        let inputs = list.orderedItems.compactMap { item -> GroceryRemindersService.InputItem? in
            guard let id = item.id, let name = item.displayName else { return nil }
            return GroceryRemindersService.InputItem(
                id: id,
                displayName: name,
                quantityText: item.quantityText,
            )
        }
        do {
            let result = try await reminders.export(items: inputs, recipeTitle: recipePlan.title ?? "Stir")
            let itemIDs: [UUID: String] = Dictionary(
                uniqueKeysWithValues: result.items.map { ($0.itemID, $0.reminderID) },
            )
            try groceryRepo.markExported(
                list,
                reminderListID: result.calendarIdentifier,
                itemReminderIDs: itemIDs,
            )
            stage = .exported
            analytics.capture(
                .groceryListExported,
                properties: StepSevenTelemetry.groceryListExported(
                    itemCount: inputs.count,
                    destination: .reminders,
                ),
            )
            // Donate the intent so Siri starts suggesting "Add to
            // grocery" contextually for repeat users. 24h cooldown is
            // honored inside the donation service.
            Task { await IntentDonationService().donateAddToGroceryIfEligible() }
            return true
        } catch let error as GroceryRemindersService.Failure {
            Logger.ui.warning("grocery reminders export: \(error.localizedDescription, privacy: .public)")
            analytics.capture(
                .groceryListExported,
                properties: StepSevenTelemetry.groceryListExported(
                    itemCount: inputs.count,
                    destination: .inApp,
                ),
            )
            switch error {
            case .authorizationDenied:
                // Stay in .ready so the user can keep using the in-app list.
                // Caller shows a Reminders-off toast.
                return false
            case .noReminderSource, .saveFailed:
                stage = .error(code: "BILL-01", message: error.errorDescription ?? "Reminders export failed.")
                return false
            }
        } catch {
            Logger.ui.error("grocery export unexpected: \(error.localizedDescription, privacy: .public)")
            // CR3-14: pre-fix this catch silently returned false — no
            // telemetry, no stage flip, no user-visible error. Now it
            // mirrors the Failure.noReminderSource path: emits the
            // inApp-destination event so the funnel stays 1:1 with
            // export attempts, transitions to .error so the UI shows
            // the retry state, and surfaces BILL-01 copy.
            analytics.capture(
                .groceryListExported,
                properties: StepSevenTelemetry.groceryListExported(
                    itemCount: inputs.count,
                    destination: .inApp,
                ),
            )
            stage = .error(code: "BILL-01", message: "Reminders export failed. Try again.")
            return false
        }
    }

    #if DEBUG
    /// Test-only hook for skipping the async `generate()` path. Stamps
    /// the VM into its terminal `.ready` state with the given list. Do
    /// NOT call from production code — generate() is the supported path.
    func _debugApplyReady(list: GroceryList) {
        self.list = list
        self.stage = .ready
    }
    #endif
}
