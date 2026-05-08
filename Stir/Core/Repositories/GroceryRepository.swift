// GroceryRepository
//
// Combined repo for GroceryList (§4.16) + GroceryItem (§4.17).
//
// Invariants enforced here (not in Core Data schema layer because
// CloudKit can't):
//   - GroceryList.status is exactly `{draft, exported}` — transitions
//     draft → exported only on successful EventKit export.
//   - GroceryItem.priority is REQUIRED on every row; default "normal"
//     when the backend response doesn't carry a value.
//   - Dedupe by (canonical_slug | normalized displayName) when inserting
//     items from the Edge Function response.

import CoreData
import Foundation

@MainActor
final class GroceryRepository {
    private let controller: PersistenceController

    init(controller: PersistenceController) {
        self.controller = controller
    }

    struct IncomingItem: Sendable {
        let displayName: String
        let quantityText: String?
        let canonicalSlug: String?
        let category: GroceryCategory
        let priority: GroceryItemPriority
    }

    // MARK: - List lifecycle

    /// Create a new draft list for the household, optionally tied to an
    /// active cooking session (spec §4.16 — sourceCookingSessionId is
    /// optional). Items are inserted on `replaceItems` so the list is
    /// visible immediately but can be empty during the Gemini round-trip.
    @discardableResult
    func createDraft(
        for household: HouseholdProfile,
        title: String,
        sourceCookingSessionID: UUID? = nil,
    ) throws -> GroceryList {
        let context = controller.viewContext
        let row = GroceryList(context: context)
        row.id = UUID()
        row.household = household
        row.title = title
        row.createdAt = Date()
        row.setStatus(.draft)
        if let sid = sourceCookingSessionID { row.sourceCookingSessionId = sid }
        try controller.save()
        return row
    }

    /// Idempotent replacement of items on a list. Removes existing items
    /// (if any) and inserts the given incoming items, respecting the
    /// dedupe rule. Preserves `sortOrder` from the incoming sequence.
    func replaceItems(on list: GroceryList, items: [IncomingItem]) throws {
        let context = controller.viewContext
        if let existing = list.items as? Set<GroceryItem> {
            for item in existing { context.delete(item) }
        }

        for (idx, incoming) in dedupedForPersistence(items).enumerated() {
            let row = GroceryItem(context: context)
            row.id = UUID()
            row.list = list
            row.displayName = incoming.displayName
            row.quantityText = incoming.quantityText
            row.canonicalIngredientSlug = incoming.canonicalSlug
            row.setCategory(incoming.category)
            row.setPriority(incoming.priority)   // required field; always set
            row.isChecked = false
            row.sortOrder = Int16(idx)
        }
        try controller.save()
    }

    /// Flip the list to `exported` + record EventKit correlation IDs.
    /// Only valid from `.draft`; calling on a row that's already exported
    /// is a no-op (safe).
    func markExported(
        _ list: GroceryList,
        reminderListID: String,
        itemReminderIDs: [UUID: String],
    ) throws {
        if list.statusEnum == .exported { return }
        list.setStatus(.exported)
        list.exportedAt = Date()
        list.reminderListId = reminderListID
        for item in list.orderedItems {
            if let id = item.id, let rid = itemReminderIDs[id] {
                item.reminderId = rid
            }
        }
        try controller.save()
    }

    /// Toggle isChecked on an item. Used by the in-app grocery list
    /// view for users who keep the list in Stir (Reminders denied path).
    func toggleChecked(_ item: GroceryItem) throws {
        item.isChecked.toggle()
        try controller.save()
    }

    // MARK: - Queries

    /// Fetch all lists for the household, newest first.
    func lists(for household: HouseholdProfile) throws -> [GroceryList] {
        let fetch: NSFetchRequest<GroceryList> = NSFetchRequest(entityName: "GroceryList")
        fetch.predicate = NSPredicate(format: "household == %@", household)
        fetch.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return try controller.viewContext.fetch(fetch)
    }

    // MARK: - Dedupe

    /// Merge incoming items by canonical_slug AND normalized display
    /// name — an entry is registered under BOTH keys so a later item
    /// with only one of them still merges into the existing bucket.
    /// Pre-fix the dedupe keyed on slug OR name only, which split:
    ///   { slug: "chicken-breast", name: "Chicken breast" }
    ///   { slug: nil,              name: "Chicken breast" }
    /// into two entries.
    ///
    /// Preserves the first occurrence's display copy + sort position,
    /// bumps priority to the highest seen, appends amount_text when
    /// different.
    func dedupedForPersistence(_ items: [IncomingItem]) -> [IncomingItem] {
        var entries: [IncomingItem] = []
        var slugIndex: [String: Int] = [:]
        var nameIndex: [String: Int] = [:]
        for item in items {
            let slugKey = item.canonicalSlug?.lowercased()
            let nameKey = Self.normalizedDisplayName(item.displayName)
            let existingIdx = slugKey.flatMap { slugIndex[$0] } ?? nameIndex[nameKey]
            if let idx = existingIdx {
                let existing = entries[idx]
                let takeNewPriority = item.priority.sortRank < existing.priority.sortRank
                let merged = IncomingItem(
                    displayName: existing.displayName,
                    quantityText: combinedQuantity(existing.quantityText, item.quantityText),
                    canonicalSlug: existing.canonicalSlug ?? item.canonicalSlug,
                    category: existing.category,
                    priority: takeNewPriority ? item.priority : existing.priority,
                )
                entries[idx] = merged
                // Register newly-learned slug/name keys for this entry
                // so subsequent items matching on the other key merge too.
                if let slugKey, slugIndex[slugKey] == nil { slugIndex[slugKey] = idx }
                if nameIndex[nameKey] == nil { nameIndex[nameKey] = idx }
            } else {
                let idx = entries.count
                entries.append(item)
                if let slugKey { slugIndex[slugKey] = idx }
                nameIndex[nameKey] = idx
            }
        }
        return entries
    }

    /// Cheap singular/plural + case normalization for display-name
    /// matching — mirrors the backend `normalizeForMatch` helper so
    /// client-side and server-side dedupe converge.
    ///
    /// The -es drop only fires for sibilant-ending plurals (classes,
    /// boxes, dishes, buzzes, peaches, potatoes). Singulars ending in
    /// -se/-ge/-me/-ne (rose, range, name) fall through to the drop-s
    /// branch so "roses"/"rose" round-trip to the same key instead of
    /// diverging to "ros"/"rose".
    static func normalizedDisplayName(_ name: String) -> String {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "  ", with: " ")
        if lowered.hasSuffix("ies"), lowered.count > 4 {
            return String(lowered.dropLast(3)) + "y"
        }
        let endsInSibilantEsPlural =
            lowered.hasSuffix("sses") ||    // class → classes
            lowered.hasSuffix("xes") ||     // box → boxes
            lowered.hasSuffix("zes") ||     // waltz → waltzes
            lowered.hasSuffix("ches") ||    // peach → peaches
            lowered.hasSuffix("shes") ||    // dish → dishes
            lowered.hasSuffix("oes")        // potato → potatoes
        if endsInSibilantEsPlural, lowered.count > 3 {
            return String(lowered.dropLast(2))
        }
        if lowered.hasSuffix("s"), lowered.count > 2, !lowered.hasSuffix("ss") {
            return String(lowered.dropLast(1))
        }
        return lowered
    }

    private func combinedQuantity(_ a: String?, _ b: String?) -> String? {
        switch (a, b) {
        case (nil, nil):
            return nil
        case let (a?, nil):
            return a
        case let (nil, b?):
            return b
        case let (a?, b?) where a == b:
            return a
        case let (a?, b?):
            return "\(a) + \(b)"
        }
    }
}
