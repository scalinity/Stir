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
