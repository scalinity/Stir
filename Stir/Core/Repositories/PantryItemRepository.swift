// PantryItemRepository
//
// CRUD over pantry rows, scoped to a HouseholdProfile.
//
// Step-3 added the scan write path (`upsertFromScan`); step 4 added
// soft-delete; the pantry management surface (ADR 0028) added read,
// count, manual insert, and edit. Step 7 will layer leftovers +
// expiration on top.
//
// Upsert semantics (used by both scan and manual paths): within a
// household, an ingredient is keyed on
// (canonicalIngredientSlug || displayName_lowercased). Existing
// rows bump lastSeenAt / amountText; new rows insert.

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

    /// Outcome of `upsertFromScan` carrying the persisted rows AND the
    /// number of ingredients whose `.likelyStaple` parseConfidence was
    /// downgraded to `.ephemeral` because the household's
    /// `.remembered` slot count would otherwise exceed `cap`. Caller
    /// surfaces `truncatedToEphemeral` as a "you're at your pantry
    /// limit — these stayed for tonight only" toast (review C1).
    struct ScanUpsertOutcome: Sendable {
        let rows: [PantryItem]
        let truncatedToEphemeral: Int
    }

    /// Upsert a batch of confirmed-by-user ingredients onto the household's
    /// pantry. Existing rows bump lastSeenAt + userConfirmed=true; new rows
    /// insert with source=.scan. All in one save.
    ///
    /// Cap enforcement: when `cap` is provided, NEW rows that would be
    /// `.remembered` (i.e. parseConfidence == .likelyStaple) downgrade
    /// to `.ephemeral` once the running cap is exhausted, rather than
    /// silently inserting unbounded `.remembered` rows. Existing-row
    /// upserts and `.ephemeral` rows are unaffected by the cap. Caller
    /// passes the entitlement service's `(usedRemembered, cap)` pair;
    /// pass `cap: nil` to skip enforcement (legacy/test paths).
    ///
    /// Without this gate, a Free user (cap 25) at quota could scan a
    /// fridge full of staples and the repo would happily insert all
    /// of them as `.remembered` — the next manual-add would refuse
    /// with "cap reached" while the header read e.g. "73 of 25 saved",
    /// breaking the upsell story for the highest-volume populate path
    /// (review C1).
    func upsertFromScan(
        _ ingredients: [ScanIngredient],
        on household: HouseholdProfile,
        usedRemembered: Int = 0,
        cap: Int? = nil,
    ) throws -> ScanUpsertOutcome {
        let context = controller.viewContext
        let now = Date()
        var results: [PantryItem] = []
        var liveUsed = usedRemembered
        var truncated = 0

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

            // Decide the new row's memory state with cap awareness. The
            // model's parseConfidence is the proposal; the cap is the
            // ceiling.
            let proposed: PantryItem.MemoryState =
                ing.parseConfidence == .likelyStaple ? .remembered : .ephemeral
            let resolved: PantryItem.MemoryState
            if proposed == .remembered, let cap, liveUsed >= cap {
                resolved = .ephemeral
                truncated += 1
            } else {
                resolved = proposed
                if resolved == .remembered {
                    liveUsed += 1
                }
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
            row.typedMemoryState = resolved
            row.lastSeenAt = now
            row.createdAt = now
            row.updatedAt = now
            results.append(row)
        }

        try controller.save()
        Logger.coreData.info(
            "PantryItemRepository upserted \(results.count, privacy: .public) rows (\(truncated, privacy: .public) downgraded to ephemeral due to cap)",
        )
        return ScanUpsertOutcome(rows: results, truncatedToEphemeral: truncated)
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

    /// Counts rows that count against the standing pantry cap (Free 25 /
    /// Premium 250 / Pro 1000 — CLAUDE.md authoritative). Counts only
    /// `.remembered`, non-deleted rows; everything else (`.ephemeral`,
    /// `.expired`, `.unknown`, soft-deleted) is excluded by the positive
    /// `memoryState == 'remembered'` predicate. Used by
    /// `PantryListViewModel` for client-side quota enforcement on
    /// manual adds.
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

    /// Outcome of an `insertManual` call. Lets the caller route a
    /// cap-rejected attempt to the paywall while distinguishing it from
    /// a transient persistence failure (a paid user with a flaky save
    /// must not be upsold to Premium — review C4 / prior PantryAddResult
    /// fix). `.upserted` covers the dedupe path: an existing row's
    /// fields were bumped, no new row was created, so the cap was not
    /// consulted.
    enum InsertManualOutcome: Equatable {
        case inserted(PantryItem)
        case upserted(PantryItem)
        case capReached
    }

    /// Insert (or upsert) a manually-added pantry item with cap
    /// enforcement baked in. Dedupes by slug-then-name (see
    /// `fetchExisting`). Manual inserts always set
    /// `userConfirmed = true` and `confidence = 1.0` (the user typed
    /// it themselves; no AI hedge needed).
    ///
    /// Cap-bookkeeping contract: the caller passes `(used, cap)` —
    /// the entitlement service is the source of truth and it lives
    /// outside the repo, so we don't read it directly. The cap is
    /// checked ONLY on the new-row branch; an upsert against an
    /// existing remembered row is allowed even when `used == cap`,
    /// because no row would be added (review C4: re-typing an
    /// existing remembered name at cap was wrongly routing paid
    /// users to the paywall). Pass `cap: nil` to skip enforcement
    /// entirely (used by tests + non-cap-bound paths).
    ///
    /// Validation: rejects empty-after-trim displayName via
    /// `StirError.validation`. Length caps on displayName (200) and
    /// amountText (100) prevent self-DoS-via-paste from corrupting
    /// CloudKit sync (review W10 — CKErrorPartialFailure on oversize
    /// CloudKit String fields).
    func insertManual(
        displayName: String,
        amountText: String?,
        memoryState: PantryItem.MemoryState = .remembered,
        on household: HouseholdProfile,
        usedRemembered: Int? = nil,
        cap: Int? = nil,
    ) throws -> InsertManualOutcome {
        let context = controller.viewContext
        let now = Date()
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw StirError.validation(
                fieldErrors: [FieldError(field: "displayName", issue: "must not be empty")],
                message: "displayName cannot be empty",
            )
        }
        guard trimmedName.count <= Self.maxDisplayNameLength else {
            throw StirError.validation(
                fieldErrors: [FieldError(
                    field: "displayName",
                    issue: "must be \(Self.maxDisplayNameLength) characters or fewer",
                )],
                message: "displayName too long",
            )
        }
        let trimmedAmount = amountText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedAmount, trimmedAmount.count > Self.maxAmountTextLength {
            throw StirError.validation(
                fieldErrors: [FieldError(
                    field: "amountText",
                    issue: "must be \(Self.maxAmountTextLength) characters or fewer",
                )],
                message: "amountText too long",
            )
        }

        if let existing = try fetchExisting(
            slug: nil,
            displayName: trimmedName,
            on: household,
            context: context,
        ) {
            existing.lastSeenAt = now
            existing.updatedAt = now
            existing.userConfirmed = true
            existing.confidence = 1.0
            existing.typedMemoryState = memoryState
            if let trimmedAmount, !trimmedAmount.isEmpty {
                existing.amountText = trimmedAmount
            }
            try controller.save()
            return .upserted(existing)
        }

        // New-row branch — apply cap only here. `.ephemeral` /
        // `.expired` / `.unknown` rows skip the cap entirely (only
        // `.remembered` counts against the standing-cap, mirroring
        // `countRemembered`).
        if memoryState == .remembered, let used = usedRemembered, let cap, used >= cap {
            return .capReached
        }

        let row = PantryItem(context: context)
        row.id = UUID()
        row.household = household
        row.displayName = trimmedName
        row.canonicalIngredientSlug = ""
        row.amountText = (trimmedAmount?.isEmpty ?? true) ? nil : trimmedAmount
        row.confidence = 1.0
        row.userConfirmed = true
        row.typedSource = .manual
        row.typedMemoryState = memoryState
        row.lastSeenAt = now
        row.createdAt = now
        row.updatedAt = now
        try controller.save()
        return .inserted(row)
    }

    /// Length caps on user-typed pantry strings. Prevents a paste of
    /// (e.g.) a 1MB string from corrupting CloudKit sync — CloudKit's
    /// String fields tolerate ≤1MB but the sync envelope is much
    /// smaller and a CKErrorPartialFailure can block the entire batch.
    /// Values are advisory (not Core Data attribute constraints) so
    /// existing CloudKit-replicated rows that pre-date this guard
    /// still load — only writes are bounded.
    static let maxDisplayNameLength: Int = 200
    static let maxAmountTextLength: Int = 100

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
        guard item.deletedAt == nil else {
            throw StirError.validation(
                fieldErrors: [FieldError(field: "deletedAt", issue: "cannot edit a soft-deleted item")],
                message: "Cannot edit a soft-deleted PantryItem",
            )
        }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw StirError.validation(
                fieldErrors: [FieldError(field: "displayName", issue: "must not be empty")],
                message: "displayName cannot be empty",
            )
        }
        guard trimmedName.count <= Self.maxDisplayNameLength else {
            throw StirError.validation(
                fieldErrors: [FieldError(
                    field: "displayName",
                    issue: "must be \(Self.maxDisplayNameLength) characters or fewer",
                )],
                message: "displayName too long",
            )
        }
        let trimmedAmount = amountText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedAmount, trimmedAmount.count > Self.maxAmountTextLength {
            throw StirError.validation(
                fieldErrors: [FieldError(
                    field: "amountText",
                    issue: "must be \(Self.maxAmountTextLength) characters or fewer",
                )],
                message: "amountText too long",
            )
        }
        item.displayName = trimmedName
        item.amountText = (trimmedAmount?.isEmpty ?? true) ? nil : trimmedAmount
        item.typedMemoryState = memoryState
        item.updatedAt = Date()
        try controller.save()
    }

    // MARK: - Private

    /// Look up an existing PantryItem to dedupe against. Match strategy:
    ///
    /// - If a non-empty `slug` is provided: try slug match FIRST, then
    ///   fall back to case-insensitive `displayName` match. Without the
    ///   name fallback, a manually-added "olive oil" (always stored
    ///   with `slug = ""` because manual entries don't carry a
    ///   canonical slug) is invisible to a later scan with
    ///   `canonicalSlug = "olive_oil"`, producing duplicate pantry
    ///   rows. The fallback closes that hole — review C5.
    /// - If no slug is provided: name match only. Manual `insertManual`
    ///   uses this path.
    ///
    /// Slug-first means a scan with a known slug will match a previous
    /// scan row (same slug) ahead of a name-shadowed manual row, which
    /// is the desired ordering: scan-vs-scan dedupes through the
    /// canonical key; scan-vs-manual falls through to name as the
    /// least-bad alternative.
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
        let byName = NSPredicate(format: "displayName ==[c] %@", displayName)

        if let slug, !slug.isEmpty {
            // Try slug first.
            let bySlug = NSPredicate(format: "canonicalIngredientSlug == %@", slug)
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [byHousehold, notDeleted, bySlug])
            do {
                if let match = try context.fetch(request).first {
                    return match
                }
            } catch {
                throw StirError.coreData(underlying: error)
            }
            // Fall back to name — see doc-comment on this function for why.
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [byHousehold, notDeleted, byName])
        } else {
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [byHousehold, notDeleted, byName])
        }

        do {
            return try context.fetch(request).first
        } catch {
            throw StirError.coreData(underlying: error)
        }
    }
}
