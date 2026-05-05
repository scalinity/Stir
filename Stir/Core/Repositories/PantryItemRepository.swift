// PantryItemRepository
//
// Step-3 scope: write confirmed ingredients from scan review. Step 4 adds
// saved-meal freshness decay; step 7 adds leftovers + expiration.
//
// Upsert semantics: within a household, an ingredient is keyed on
// (canonicalIngredientSlug || displayName_lowercased). When the user
// confirms an ingredient from the scan-review chips, we either insert a
// new row or bump lastSeenAt / amountText on the existing row.

import CoreData
import Foundation
import OSLog

@MainActor
final class PantryItemRepository {
    private let controller: PersistenceController

    init(controller: PersistenceController = .shared) {
        self.controller = controller
    }

    struct ScanIngredient: Sendable {
        let displayName: String
        let canonicalSlug: String?
        let amountText: String?
        let confidence: Double
        let parseConfidence: PantryItem.ParseConfidence
    }

    /// Upsert a batch of confirmed-by-user ingredients onto the household's
    /// pantry. Existing rows bump lastSeenAt + userConfirmed=true; new rows
    /// insert with source=.scan. All in one save.
    @discardableResult
    func upsertFromScan(
        _ ingredients: [ScanIngredient],
        on household: HouseholdProfile,
    ) throws -> [PantryItem] {
        let context = controller.viewContext
        let now = Date()
        var results: [PantryItem] = []

        for ing in ingredients {
            let match = try fetchExisting(
                slug: ing.canonicalSlug,
                displayName: ing.displayName,
                on: household,
                context: context,
            )

            if let existing = match {
                existing.lastSeenAt = now
                existing.updatedAt = now
                existing.userConfirmed = true
                existing.confidence = max(existing.confidence, ing.confidence)
                if let amountText = ing.amountText, existing.amountText?.isEmpty ?? true {
                    existing.amountText = amountText
                }
                results.append(existing)
                continue
            }

            let row = PantryItem(context: context)
            row.id = UUID()
            row.household = household
            row.canonicalIngredientSlug = ing.canonicalSlug ?? ""
            row.displayName = ing.displayName
            row.amountText = ing.amountText
            row.confidence = ing.confidence
            row.userConfirmed = true
            row.typedSource = .scan
            row.typedMemoryState = ing.parseConfidence == .likelyStaple ? .remembered : .ephemeral
            row.lastSeenAt = now
            row.createdAt = now
            row.updatedAt = now
            results.append(row)
        }

        try controller.save()
        Logger.coreData.info("PantryItemRepository upserted \(results.count, privacy: .public) rows")
        return results
    }

    /// Soft-delete a pantry item.
    func softDelete(_ item: PantryItem) throws {
        item.deletedAt = Date()
        item.updatedAt = Date()
        try controller.save()
    }

    /// Read all PantryItem rows scoped to a household, sorted by
    /// `lastSeenAt` descending (most-recently-seen first). Soft-deleted
    /// rows are filtered by default; pass `includeSoftDeleted: true` for
    /// admin / debug surfaces.
    ///
    /// Returns NSManagedObjects (not value-types) because the pantry view
    /// uses `@ObservedObject` rows for live KVO redraws on edit — same
    /// pattern as `GroceryListView.AisleRow` consuming `GroceryItem`
    /// directly. Tonight Home uses a value-type projection because its
    /// hero card stores the dish across the lifetime of the screen and
    /// would race with CloudKit conflict resolution; the pantry list
    /// re-fetches on every view appear, so the fault risk is bounded.
    func fetchAll(
        for household: HouseholdProfile,
        includeSoftDeleted: Bool = false,
    ) throws -> [PantryItem] {
        let request = NSFetchRequest<PantryItem>(entityName: "PantryItem")
        var predicates: [NSPredicate] = [
            NSPredicate(format: "household == %@", household),
        ]
        if !includeSoftDeleted {
            predicates.append(NSPredicate(format: "deletedAt == nil"))
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [
            NSSortDescriptor(key: "lastSeenAt", ascending: false),
            NSSortDescriptor(key: "displayName", ascending: true),
        ]
        do {
            return try controller.viewContext.fetch(request)
        } catch {
            throw StirError.coreData(underlying: error)
        }
    }

    /// Count rows that count against the standing pantry cap (Free 25 /
    /// Premium 250 / Pro 1000 — CLAUDE.md authoritative). Excludes
    /// `.ephemeral` (today-only matches), `.expired` (past expiresAt),
    /// `.unknown`, and soft-deleted rows. Used by `PantryListViewModel`
    /// for client-side quota enforcement on manual adds.
    func countRemembered(for household: HouseholdProfile) throws -> Int {
        let request = NSFetchRequest<PantryItem>(entityName: "PantryItem")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "household == %@", household),
            NSPredicate(format: "deletedAt == nil"),
            NSPredicate(format: "memoryState == %@", PantryItem.MemoryState.remembered.rawValue),
        ])
        do {
            return try controller.viewContext.count(for: request)
        } catch {
            throw StirError.coreData(underlying: error)
        }
    }

    /// Insert (or upsert) a manually-added pantry item. Reuses the same
    /// dedupe rule as `upsertFromScan` — case-insensitive `displayName`
    /// or matching `canonicalIngredientSlug` updates the existing row
    /// rather than creating a duplicate. Manual inserts always set
    /// `userConfirmed = true` and `confidence = 1.0` (the user typed it
    /// themselves; no AI hedge needed).
    @discardableResult
    func insertManual(
        displayName: String,
        amountText: String?,
        memoryState: PantryItem.MemoryState = .remembered,
        on household: HouseholdProfile,
    ) throws -> PantryItem {
        let context = controller.viewContext
        let now = Date()
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw StirError.coreData(underlying: NSError(
                domain: "PantryItemRepository",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "displayName cannot be empty"],
            ))
        }
        let trimmedAmount = amountText?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existing = try fetchExisting(
            slug: nil,
            displayName: trimmedName,
            on: household,
            context: context,
        ) {
            existing.lastSeenAt = now
            existing.updatedAt = now
            existing.userConfirmed = true
            existing.confidence = max(existing.confidence, 1.0)
            existing.typedMemoryState = memoryState
            if let trimmedAmount, !trimmedAmount.isEmpty {
                existing.amountText = trimmedAmount
            }
            try controller.save()
            return existing
        }

        let row = PantryItem(context: context)
        row.id = UUID()
        row.household = household
        row.displayName = trimmedName
        row.canonicalIngredientSlug = ""
        row.amountText = trimmedAmount?.isEmpty == false ? trimmedAmount : nil
        row.confidence = 1.0
        row.userConfirmed = true
        row.typedSource = .manual
        row.typedMemoryState = memoryState
        row.lastSeenAt = now
        row.createdAt = now
        row.updatedAt = now
        try controller.save()
        return row
    }

    /// Mutate an existing pantry row's user-editable fields. Used by
    /// `PantryEditSheet`. Bumps `updatedAt` so CloudKit sync propagates.
    /// Trims whitespace and reapplies the same nil-on-blank rule as
    /// `insertManual`.
    func update(
        _ item: PantryItem,
        displayName: String,
        amountText: String?,
        memoryState: PantryItem.MemoryState,
    ) throws {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw StirError.coreData(underlying: NSError(
                domain: "PantryItemRepository",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "displayName cannot be empty"],
            ))
        }
        let trimmedAmount = amountText?.trimmingCharacters(in: .whitespacesAndNewlines)
        item.displayName = trimmedName
        item.amountText = (trimmedAmount?.isEmpty ?? true) ? nil : trimmedAmount
        item.typedMemoryState = memoryState
        item.updatedAt = Date()
        try controller.save()
    }

    // MARK: - Private

    private func fetchExisting(
        slug: String?,
        displayName: String,
        on household: HouseholdProfile,
        context: NSManagedObjectContext,
    ) throws -> PantryItem? {
        let request = NSFetchRequest<PantryItem>(entityName: "PantryItem")
        request.fetchLimit = 1

        let byHousehold = NSPredicate(format: "household == %@", household)
        let notDeleted = NSPredicate(format: "deletedAt == nil")

        if let slug, !slug.isEmpty {
            let bySlug = NSPredicate(format: "canonicalIngredientSlug == %@", slug)
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [byHousehold, notDeleted, bySlug])
        } else {
            let byName = NSPredicate(format: "displayName ==[c] %@", displayName)
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [byHousehold, notDeleted, byName])
        }

        do {
            return try context.fetch(request).first
        } catch {
            throw StirError.coreData(underlying: error)
        }
    }
}
