// PantryItemRepositoryTests
//
// Coverage for read + manual-write + edit + count APIs added for the
// pantry management surface (ADR 0028). Uses an in-memory persistent
// store via `PersistenceController(inMemory: true)`.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class PantryItemRepositoryTests: XCTestCase {
    private var pc: PersistenceController!
    private var household: HouseholdProfile!
    private var repo: PantryItemRepository!

    override func setUp() async throws {
        try await super.setUp()
        pc = PersistenceController(inMemory: true)
        repo = PantryItemRepository(controller: pc)
        let ctx = pc.viewContext
        household = HouseholdProfile(context: ctx)
        household.id = UUID()
        household.createdAt = Date()
        try ctx.save()
    }

    override func tearDown() async throws {
        pc = nil
        household = nil
        repo = nil
        try await super.tearDown()
    }

    // MARK: - Read

    func test_fetchAll_returnsRowsExcludingSoftDeleted() throws {
        try seedItem(name: "olive oil", deleted: false)
        try seedItem(name: "flour", deleted: true)
        let rows = try repo.fetchAll(for: household, includeSoftDeleted: false)
        XCTAssertEqual(rows.map(\.displayName), ["olive oil"])
    }

    func test_countRemembered_excludesEphemeralAndDeleted() throws {
        try seedItem(name: "olive oil", memoryState: .remembered)
        try seedItem(name: "garlic", memoryState: .remembered)
        try seedItem(name: "fresh basil", memoryState: .ephemeral)
        try seedItem(name: "stale flour", memoryState: .remembered, deleted: true)
        let count = try repo.countRemembered(for: household)
        XCTAssertEqual(count, 2, "only non-deleted .remembered rows count toward the cap")
    }

    func test_fetchAll_isolatesByHousehold() throws {
        let other = HouseholdProfile(context: pc.viewContext)
        other.id = UUID()
        other.createdAt = Date()
        try pc.viewContext.save()

        try seedItem(name: "ours", deleted: false)
        let ourCount = try repo.fetchAll(for: household).count
        XCTAssertEqual(ourCount, 1)

        let theirRow = PantryItem(context: pc.viewContext)
        theirRow.id = UUID()
        theirRow.household = other
        theirRow.displayName = "theirs"
        theirRow.canonicalIngredientSlug = ""
        theirRow.typedSource = .manual
        theirRow.typedMemoryState = .remembered
        theirRow.userConfirmed = true
        theirRow.createdAt = Date()
        theirRow.updatedAt = Date()
        theirRow.lastSeenAt = Date()
        try pc.viewContext.save()

        XCTAssertEqual(try repo.fetchAll(for: household).map(\.displayName), ["ours"])
        XCTAssertEqual(try repo.fetchAll(for: other).map(\.displayName), ["theirs"])
        XCTAssertEqual(try repo.countRemembered(for: household), 1)
        XCTAssertEqual(try repo.countRemembered(for: other), 1)
    }

    func test_fetchAll_sortsByLastSeenDescThenNameAsc() throws {
        let now = Date()
        try seedItem(name: "older", lastSeenAt: now.addingTimeInterval(-3600))
        try seedItem(name: "alpha-newest", lastSeenAt: now)
        try seedItem(name: "beta-newest", lastSeenAt: now)
        let names = try repo.fetchAll(for: household).map(\.displayName)
        XCTAssertEqual(names, ["alpha-newest", "beta-newest", "older"])
    }

    func test_fetchAll_includeSoftDeleted_surfacesDeletedRows() throws {
        try seedItem(name: "live")
        try seedItem(name: "tombstone", deleted: true)
        let withDeleted = try repo.fetchAll(for: household, includeSoftDeleted: true)
        XCTAssertEqual(Set(withDeleted.map(\.displayName)), ["live", "tombstone"])
    }

    // MARK: - insertManual

    func test_insertManual_persistsRowAndDedupesAgainstExisting() throws {
        let first = try insertedRow(displayName: "olive oil", amount: "1 bottle")
        XCTAssertEqual(first.displayName, "olive oil")
        XCTAssertEqual(first.typedSource, .manual)
        XCTAssertEqual(first.typedMemoryState, .remembered)

        let secondOutcome = try repo.insertManual(
            displayName: "olive oil",
            amountText: "2 bottles",
            memoryState: .remembered,
            on: household,
        )
        guard case .upserted = secondOutcome else {
            return XCTFail("expected .upserted on dedupe; got \(secondOutcome)")
        }
        let rows = try repo.fetchAll(for: household)
        XCTAssertEqual(rows.count, 1, "case-insensitive name dedupe")
        XCTAssertEqual(rows.first?.amountText, "2 bottles", "amount overwrites on dedupe")
    }

    /// Review C5 regression test — manual entry first, then a scan
    /// row with a canonical slug for the same item must dedupe to
    /// the manual row instead of producing a duplicate.
    func test_fetchExisting_slugFallsBackToNameWhenSlugMisses() throws {
        _ = try insertedRow(displayName: "olive oil", amount: nil)
        // Now upsert via the scan path (slug-aware) — should resolve
        // back to the manual row by name fallback.
        let outcome = try repo.upsertFromScan(
            [
                PantryItemRepository.ScanIngredient(
                    displayName: "olive oil",
                    canonicalSlug: "olive_oil",
                    amountText: "1 bottle",
                    confidence: 0.9,
                    parseConfidence: .confirmed,
                ),
            ],
            on: household,
        )
        XCTAssertEqual(outcome.rows.count, 1)
        let allRows = try repo.fetchAll(for: household)
        XCTAssertEqual(allRows.count, 1, "manual + scan dedupe via name fallback")
    }

    /// Review C4 regression test — at-cap re-add of an EXISTING
    /// remembered row must upsert (no row added), not return
    /// `.capReached`.
    func test_insertManual_atCap_reAddingExistingUpsertsInsteadOfPaywall() throws {
        for i in 0 ..< 25 {
            _ = try insertedRow(displayName: "item-\(i)", amount: nil)
        }
        let outcome = try repo.insertManual(
            displayName: "item-0",
            amountText: nil,
            memoryState: .remembered,
            on: household,
            usedRemembered: 25,
            cap: 25,
        )
        guard case .upserted = outcome else {
            return XCTFail("at-cap re-add of existing row should upsert; got \(outcome)")
        }
        XCTAssertEqual(try repo.fetchAll(for: household).count, 25, "no new row was created")
    }

    func test_insertManual_atCap_newNameReturnsCapReached() throws {
        for i in 0 ..< 25 {
            _ = try insertedRow(displayName: "item-\(i)", amount: nil)
        }
        let outcome = try repo.insertManual(
            displayName: "over-cap",
            amountText: nil,
            memoryState: .remembered,
            on: household,
            usedRemembered: 25,
            cap: 25,
        )
        guard case .capReached = outcome else {
            return XCTFail("new-name at cap should be .capReached; got \(outcome)")
        }
        XCTAssertEqual(try repo.fetchAll(for: household).count, 25, "no row written")
    }

    func test_insertManual_ephemeralBypassesCap() throws {
        for i in 0 ..< 25 {
            _ = try insertedRow(displayName: "item-\(i)", amount: nil)
        }
        let outcome = try repo.insertManual(
            displayName: "fresh basil",
            amountText: nil,
            memoryState: .ephemeral,
            on: household,
            usedRemembered: 25,
            cap: 25,
        )
        guard case .inserted = outcome else {
            return XCTFail("ephemeral at cap should insert; got \(outcome)")
        }
    }

    func test_insertManual_throwsValidationOnEmptyDisplayName() throws {
        XCTAssertThrowsError(try repo.insertManual(
            displayName: "   ",
            amountText: nil,
            on: household,
        )) { error in
            guard case StirError.validation = error else {
                XCTFail("expected .validation, got \(error)")
                return
            }
        }
    }

    func test_insertManual_throwsValidationOnOverlongDisplayName() throws {
        let tooLong = String(repeating: "a", count: PantryItemRepository.maxDisplayNameLength + 1)
        XCTAssertThrowsError(try repo.insertManual(
            displayName: tooLong,
            amountText: nil,
            on: household,
        )) { error in
            guard case StirError.validation = error else {
                XCTFail("expected .validation, got \(error)")
                return
            }
        }
    }

    func test_insertManual_throwsValidationOnOverlongAmountText() throws {
        let tooLong = String(repeating: "a", count: PantryItemRepository.maxAmountTextLength + 1)
        XCTAssertThrowsError(try repo.insertManual(
            displayName: "olive oil",
            amountText: tooLong,
            on: household,
        )) { error in
            guard case StirError.validation = error else {
                XCTFail("expected .validation, got \(error)")
                return
            }
        }
    }

    // MARK: - update

    func test_update_setsFieldsAndBumpsUpdatedAt() async throws {
        let row = try insertedRow(displayName: "olive oil", amount: "1 bottle")
        let originalUpdate = row.updatedAt
        try await Task.sleep(nanoseconds: 50_000_000)
        try repo.update(
            row,
            displayName: "extra-virgin olive oil",
            amountText: "2 bottles",
            memoryState: .remembered,
        )
        XCTAssertEqual(row.displayName, "extra-virgin olive oil")
        XCTAssertEqual(row.amountText, "2 bottles")
        XCTAssertGreaterThan(row.updatedAt ?? .distantPast, originalUpdate ?? .distantPast)
    }

    func test_update_throwsValidationOnEmptyDisplayName() throws {
        let row = try insertedRow(displayName: "olive oil", amount: nil)
        XCTAssertThrowsError(try repo.update(
            row,
            displayName: "",
            amountText: nil,
            memoryState: .remembered,
        )) { error in
            guard case StirError.validation = error else {
                XCTFail("expected .validation, got \(error)")
                return
            }
        }
    }

    /// Review W9 — previously asserted `XCTAssertThrowsError` without
    /// inspecting the error case, which would have passed for any
    /// thrown value. Now pattern-matches `.validation`.
    func test_update_throwsValidationOnSoftDeletedItem() throws {
        let row = try insertedRow(displayName: "olive oil", amount: nil)
        try repo.softDelete(row)
        XCTAssertThrowsError(try repo.update(
            row,
            displayName: "EVOO",
            amountText: nil,
            memoryState: .remembered,
        )) { error in
            guard case StirError.validation = error else {
                XCTFail("expected .validation, got \(error)")
                return
            }
        }
    }

    func test_update_throwsValidationOnOverlongDisplayName() throws {
        let row = try insertedRow(displayName: "olive oil", amount: nil)
        let tooLong = String(repeating: "a", count: PantryItemRepository.maxDisplayNameLength + 1)
        XCTAssertThrowsError(try repo.update(
            row,
            displayName: tooLong,
            amountText: nil,
            memoryState: .remembered,
        )) { error in
            guard case StirError.validation = error else {
                XCTFail("expected .validation, got \(error)")
                return
            }
        }
    }

    // MARK: - upsertFromScan cap-aware

    /// Review C1 regression test — `.likelyStaple` rows past the cap
    /// downgrade to `.ephemeral` instead of silently exceeding it.
    func test_upsertFromScan_downgradesStaplesPastCapToEphemeral() throws {
        // Seed up to the cap with manual remembered rows.
        for i in 0 ..< 25 {
            _ = try insertedRow(displayName: "manual-\(i)", amount: nil)
        }
        // Scan adds 3 staples — all would-be `.remembered`.
        let scan = (0 ..< 3).map { i in
            PantryItemRepository.ScanIngredient(
                displayName: "scan-\(i)",
                canonicalSlug: "scan_\(i)",
                amountText: nil,
                confidence: 0.9,
                parseConfidence: .likelyStaple,
            )
        }
        let outcome = try repo.upsertFromScan(
            scan,
            on: household,
            usedRemembered: 25,
            cap: 25,
        )
        XCTAssertEqual(outcome.truncatedToEphemeral, 3)
        XCTAssertEqual(try repo.countRemembered(for: household), 25, "cap respected")
        let scanRows = try repo.fetchAll(for: household).filter { ($0.displayName ?? "").hasPrefix("scan-") }
        XCTAssertEqual(scanRows.count, 3)
        XCTAssertTrue(scanRows.allSatisfy { $0.typedMemoryState == .ephemeral })
    }

    func test_upsertFromScan_belowCapKeepsStaplesRemembered() throws {
        let scan = [
            PantryItemRepository.ScanIngredient(
                displayName: "olive oil",
                canonicalSlug: "olive_oil",
                amountText: nil,
                confidence: 0.9,
                parseConfidence: .likelyStaple,
            ),
        ]
        let outcome = try repo.upsertFromScan(
            scan,
            on: household,
            usedRemembered: 0,
            cap: 25,
        )
        XCTAssertEqual(outcome.truncatedToEphemeral, 0)
        XCTAssertEqual(try repo.countRemembered(for: household), 1)
    }

    // MARK: - Helpers

    /// Unwraps an `InsertManualOutcome.inserted(row)` for tests that
    /// only care about the produced row. Fails the test on any other
    /// outcome — call sites that genuinely want `.upserted` /
    /// `.capReached` switch on the outcome directly.
    private func insertedRow(
        displayName: String,
        amount: String?,
        memoryState: PantryItem.MemoryState = .remembered,
    ) throws -> PantryItem {
        let outcome = try repo.insertManual(
            displayName: displayName,
            amountText: amount,
            memoryState: memoryState,
            on: household,
        )
        switch outcome {
        case .inserted(let row): return row
        case .upserted(let row): return row
        case .capReached:
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "unexpected .capReached in insertedRow helper — pass cap arg explicitly to test cap behavior"])
        }
    }

    @discardableResult
    private func seedItem(
        name: String,
        slug: String? = nil,
        memoryState: PantryItem.MemoryState = .remembered,
        deleted: Bool = false,
        lastSeenAt: Date? = nil,
    ) throws -> PantryItem {
        let row = PantryItem(context: pc.viewContext)
        row.id = UUID()
        row.household = household
        row.displayName = name
        row.canonicalIngredientSlug = slug ?? ""
        row.typedSource = .manual
        row.typedMemoryState = memoryState
        row.userConfirmed = true
        row.createdAt = Date()
        row.updatedAt = Date()
        row.lastSeenAt = lastSeenAt ?? Date()
        if deleted { row.deletedAt = Date() }
        try pc.viewContext.save()
        return row
    }

    // MARK: - softDeleteAll

    func test_softDeleteAll_softDeletesEveryNonDeletedRow() throws {
        let a = try seedItem(name: "olive oil", memoryState: .remembered)
        let b = try seedItem(name: "fresh basil", memoryState: .ephemeral)
        let c = try seedItem(name: "garlic", memoryState: .remembered)
        let count = try repo.softDeleteAll(for: household)
        XCTAssertEqual(count, 3)
        XCTAssertNotNil(a.deletedAt)
        XCTAssertNotNil(b.deletedAt)
        XCTAssertNotNil(c.deletedAt)
        XCTAssertTrue(try repo.fetchAll(for: household).isEmpty)
    }

    func test_softDeleteAll_isIdempotent_returns_zero_on_second_call() throws {
        try seedItem(name: "olive oil")
        try seedItem(name: "garlic")
        let first = try repo.softDeleteAll(for: household)
        let second = try repo.softDeleteAll(for: household)
        XCTAssertEqual(first, 2)
        XCTAssertEqual(second, 0, "re-call after all rows deleted must return 0 — fetch predicate filters deletedAt == nil")
    }

    func test_softDeleteAll_emptyPantry_returnsZero() throws {
        let count = try repo.softDeleteAll(for: household)
        XCTAssertEqual(count, 0)
    }

    func test_softDeleteAll_isolatesByHousehold() throws {
        let other = HouseholdProfile(context: pc.viewContext)
        other.id = UUID()
        other.createdAt = Date()
        try pc.viewContext.save()

        let theirRow = PantryItem(context: pc.viewContext)
        theirRow.id = UUID()
        theirRow.household = other
        theirRow.displayName = "theirs"
        theirRow.canonicalIngredientSlug = ""
        theirRow.typedSource = .manual
        theirRow.typedMemoryState = .remembered
        theirRow.userConfirmed = true
        theirRow.createdAt = Date()
        theirRow.updatedAt = Date()
        theirRow.lastSeenAt = Date()
        try pc.viewContext.save()

        try seedItem(name: "ours")

        let count = try repo.softDeleteAll(for: household)
        XCTAssertEqual(count, 1, "softDeleteAll must scope to the supplied household only")
        XCTAssertNil(theirRow.deletedAt, "other household's rows must remain untouched")
        XCTAssertEqual(try repo.fetchAll(for: other).count, 1)
    }

    // MARK: - consumeForRecipe (SCA-21)

    func test_consumeForRecipe_softDeletesEphemeralMatch() throws {
        let row = try seedItem(name: "fresh basil", slug: "fresh_basil", memoryState: .ephemeral)
        let plan = try makeRecipePlan(ingredients: [(name: "fresh basil", slug: "fresh_basil", optional: false)])

        let outcome = try repo.consumeForRecipe(plan, substitutions: [], on: household)

        XCTAssertEqual(outcome.ephemeralDeleted.map(\.objectID), [row.objectID])
        XCTAssertTrue(outcome.rememberedBumped.isEmpty)
        XCTAssertEqual(outcome.unmatched, 0)
        XCTAssertNotNil(row.deletedAt, "ephemeral row should be soft-deleted by consume")
    }

    func test_consumeForRecipe_bumpsRememberedMatch_doesNotDelete() throws {
        let row = try seedItem(
            name: "olive oil",
            slug: "olive_oil",
            memoryState: .remembered,
            lastSeenAt: Date(timeIntervalSinceNow: -86_400),
        )
        let originalLastSeen = row.lastSeenAt
        let plan = try makeRecipePlan(ingredients: [(name: "olive oil", slug: "olive_oil", optional: false)])
        let now = Date()

        let outcome = try repo.consumeForRecipe(plan, substitutions: [], on: household, now: now)

        XCTAssertEqual(outcome.rememberedBumped.map(\.objectID), [row.objectID])
        XCTAssertTrue(outcome.ephemeralDeleted.isEmpty)
        XCTAssertNil(row.deletedAt, "remembered row must NOT be deleted by a single cook")
        XCTAssertEqual(row.lastSeenAt, now)
        XCTAssertNotEqual(row.lastSeenAt, originalLastSeen)
    }

    func test_consumeForRecipe_skipsOptionalIngredients() throws {
        let req = try seedItem(name: "tomato", slug: "tomato", memoryState: .ephemeral)
        let opt = try seedItem(name: "parsley", slug: "parsley", memoryState: .ephemeral)
        let plan = try makeRecipePlan(ingredients: [
            (name: "tomato", slug: "tomato", optional: false),
            (name: "parsley", slug: "parsley", optional: true),
        ])

        let outcome = try repo.consumeForRecipe(plan, substitutions: [], on: household)

        XCTAssertEqual(outcome.ephemeralDeleted.map(\.objectID), [req.objectID])
        XCTAssertEqual(outcome.optionalSkipped, 1)
        XCTAssertNotNil(req.deletedAt)
        XCTAssertNil(opt.deletedAt, "optional ingredient must not consume the matching pantry row")
    }

    func test_consumeForRecipe_unmatchedIngredient_increments_count_no_pantry_mutation() throws {
        let row = try seedItem(name: "carrot", slug: "carrot", memoryState: .ephemeral)
        let plan = try makeRecipePlan(ingredients: [(name: "saffron", slug: "saffron", optional: false)])

        let outcome = try repo.consumeForRecipe(plan, substitutions: [], on: household)

        XCTAssertEqual(outcome.unmatched, 1)
        XCTAssertTrue(outcome.ephemeralDeleted.isEmpty)
        XCTAssertNil(row.deletedAt, "unrelated pantry row must be untouched")
    }

    func test_consumeForRecipe_appliesSubstitutionSwap_consumesSwapInLeavesOriginalAlone() throws {
        // User has both olive oil (the original recipe ingredient) and butter (the swap).
        // Recipe says olive oil, the user accepted "use butter instead", so consume should:
        //   - leave olive oil alone (user chose not to use it; might still have it)
        //   - consume butter (the swap; matches an ephemeral row)
        let oliveOil = try seedItem(name: "olive oil", slug: "olive_oil", memoryState: .remembered)
        let butter = try seedItem(name: "butter", slug: "butter", memoryState: .ephemeral)
        let plan = try makeRecipePlan(ingredients: [(name: "olive oil", slug: "olive_oil", optional: false)])
        // Note: applyAcceptedSwap (in the substitution feature path) mutates
        // recipeIngredient.displayName to the swap text. The consume routine
        // doesn't depend on that — it reads the swap from the event itself
        // — so the fixture leaves displayName as the original.
        let event = try makeSubstitutionEvent(
            for: plan.ingredientArray[0],
            acceptedSwap: "butter",
        )

        let outcome = try repo.consumeForRecipe(plan, substitutions: [event], on: household)

        XCTAssertEqual(outcome.substitutedCount, 1)
        XCTAssertEqual(outcome.ephemeralDeleted.map(\.objectID), [butter.objectID])
        XCTAssertTrue(outcome.rememberedBumped.isEmpty, "olive oil must not be bumped — user swapped it out, not in")
        XCTAssertNil(oliveOil.deletedAt)
        XCTAssertNotNil(butter.deletedAt)
    }

    func test_consumeForRecipe_rejectedSubstitution_falls_through_to_original() throws {
        // Substitution proposed but user REJECTED it (kept the original).
        // Consume should treat this as if no swap happened.
        let oliveOil = try seedItem(name: "olive oil", slug: "olive_oil", memoryState: .ephemeral)
        let plan = try makeRecipePlan(ingredients: [(name: "olive oil", slug: "olive_oil", optional: false)])
        let event = try makeSubstitutionEvent(
            for: plan.ingredientArray[0],
            acceptedSwap: nil, // rejected
        )

        let outcome = try repo.consumeForRecipe(plan, substitutions: [event], on: household)

        XCTAssertEqual(outcome.substitutedCount, 0, "rejected events don't count as substitutions")
        XCTAssertEqual(outcome.ephemeralDeleted.map(\.objectID), [oliveOil.objectID])
    }

    func test_consumeForRecipe_expiredAndUnknownState_noOp() throws {
        let expired = try seedItem(name: "old herbs", slug: "old_herbs", memoryState: .expired)
        let unknown = try seedItem(name: "mystery jar", slug: "mystery_jar", memoryState: .unknown)
        let plan = try makeRecipePlan(ingredients: [
            (name: "old herbs", slug: "old_herbs", optional: false),
            (name: "mystery jar", slug: "mystery_jar", optional: false),
        ])

        let outcome = try repo.consumeForRecipe(plan, substitutions: [], on: household)

        XCTAssertTrue(outcome.ephemeralDeleted.isEmpty)
        XCTAssertTrue(outcome.rememberedBumped.isEmpty)
        XCTAssertNil(expired.deletedAt, ".expired state must not be auto-mutated by consume — SCA-22 owns those transitions")
        XCTAssertNil(unknown.deletedAt)
    }

    func test_consumeForRecipe_mixedOutcome_telemetryPropertiesAreAccurate() throws {
        // 4 ingredients: one delete, one bump, one optional, one no-match.
        let toDelete = try seedItem(name: "tomato", slug: "tomato", memoryState: .ephemeral)
        let toBump = try seedItem(name: "salt", slug: "salt", memoryState: .remembered)
        try seedItem(name: "ignored", slug: "ignored", memoryState: .ephemeral)
        let plan = try makeRecipePlan(ingredients: [
            (name: "tomato", slug: "tomato", optional: false),
            (name: "salt", slug: "salt", optional: false),
            (name: "parsley", slug: "parsley", optional: true), // optional → skipped
            (name: "saffron", slug: "saffron", optional: false), // unmatched
        ])

        let outcome = try repo.consumeForRecipe(plan, substitutions: [], on: household)

        XCTAssertEqual(outcome.ephemeralDeleted.map(\.objectID), [toDelete.objectID])
        XCTAssertEqual(outcome.rememberedBumped.map(\.objectID), [toBump.objectID])
        XCTAssertEqual(outcome.unmatched, 1)
        XCTAssertEqual(outcome.optionalSkipped, 1)
        XCTAssertEqual(outcome.substitutedCount, 0)
        XCTAssertEqual(outcome.telemetryProperties["ephemeral_deleted"] as? Int, 1)
        XCTAssertEqual(outcome.telemetryProperties["remembered_bumped"] as? Int, 1)
        XCTAssertEqual(outcome.telemetryProperties["unmatched"] as? Int, 1)
        XCTAssertEqual(outcome.telemetryProperties["optional_skipped"] as? Int, 1)
        XCTAssertEqual(outcome.telemetryProperties["substituted_count"] as? Int, 0)
    }

    func test_consumeForRecipe_emptyRecipe_returnsAllZeroOutcome() throws {
        let plan = try makeRecipePlan(ingredients: [])

        let outcome = try repo.consumeForRecipe(plan, substitutions: [], on: household)

        XCTAssertTrue(outcome.ephemeralDeleted.isEmpty)
        XCTAssertTrue(outcome.rememberedBumped.isEmpty)
        XCTAssertEqual(outcome.unmatched, 0)
        XCTAssertEqual(outcome.optionalSkipped, 0)
        XCTAssertEqual(outcome.substitutedCount, 0)
    }

    func test_consumeForRecipe_whitespaceOnlySwap_fallsThroughToOriginal() throws {
        // SubstitutionEvent recorded `acceptedAlternativeText = "   "`
        // — the trim+isEmpty guard in `consumeForRecipe` rejects this
        // as a real substitution and falls back to the original
        // ingredient, mirroring the rejected-event path.
        let oliveOil = try seedItem(name: "olive oil", slug: "olive_oil", memoryState: .ephemeral)
        let plan = try makeRecipePlan(ingredients: [(name: "olive oil", slug: "olive_oil", optional: false)])
        let event = SubstitutionEvent(context: pc.viewContext)
        event.id = UUID()
        event.createdAt = Date()
        event.recipeIngredient = plan.ingredientArray[0]
        event.typedAcceptance = .accepted
        event.acceptedAlternativeText = "   "
        try pc.viewContext.save()

        let outcome = try repo.consumeForRecipe(plan, substitutions: [event], on: household)

        XCTAssertEqual(outcome.substitutedCount, 0, "whitespace-only swap is not a real substitution")
        XCTAssertEqual(outcome.ephemeralDeleted.map(\.objectID), [oliveOil.objectID])
    }

    func test_consumeForRecipe_eventWithNilIngredientFK_isIgnored() throws {
        // Defensive: SubstitutionEvent → RecipeIngredient is `Nullify`-
        // cascaded in the schema, so a deleted ingredient leaves the
        // event's FK nil. The consume routine must not crash and must
        // not count such an event as a substitution. The original
        // recipe ingredient is still consumed via its normal path.
        let tomato = try seedItem(name: "tomato", slug: "tomato", memoryState: .ephemeral)
        let plan = try makeRecipePlan(ingredients: [(name: "tomato", slug: "tomato", optional: false)])
        let orphanedEvent = SubstitutionEvent(context: pc.viewContext)
        orphanedEvent.id = UUID()
        orphanedEvent.createdAt = Date()
        orphanedEvent.typedAcceptance = .accepted
        orphanedEvent.acceptedAlternativeText = "butter"
        // recipeIngredient deliberately left nil
        try pc.viewContext.save()

        let outcome = try repo.consumeForRecipe(plan, substitutions: [orphanedEvent], on: household)

        XCTAssertEqual(outcome.substitutedCount, 0, "FK-less event must not count as substitution")
        XCTAssertEqual(outcome.ephemeralDeleted.map(\.objectID), [tomato.objectID])
    }

    func test_consumeForRecipe_blankIngredientName_countsAsUnmatched() throws {
        // W1 regression test: a recipe row with a blank effective name
        // (model hallucination / malformed import) used to silently
        // skip without counting, breaking the four-counters-sum-to-
        // ingredients-walked invariant the ADR 0029 trigger relies on.
        // Now counted as `unmatched` since "no pantry-row match"
        // describes the situation regardless of cause.
        try seedItem(name: "tomato", slug: "tomato", memoryState: .ephemeral)
        let plan = try makeRecipePlan(ingredients: [
            (name: "tomato", slug: "tomato", optional: false),
            (name: "", slug: nil, optional: false),
        ])

        let outcome = try repo.consumeForRecipe(plan, substitutions: [], on: household)

        XCTAssertEqual(outcome.ephemeralDeleted.count, 1)
        XCTAssertEqual(outcome.unmatched, 1, "blank-name ingredient must count as unmatched (W1)")
        XCTAssertEqual(outcome.optionalSkipped, 0)
    }

    // MARK: - Test fixtures for consumeForRecipe

    @discardableResult
    private func makeRecipePlan(
        ingredients: [(name: String, slug: String?, optional: Bool)],
    ) throws -> RecipePlan {
        let ctx = pc.viewContext
        let plan = RecipePlan(context: ctx)
        plan.id = UUID()
        plan.title = "Test recipe"
        plan.createdAt = Date()
        plan.updatedAt = Date()
        plan.household = household
        for (idx, ing) in ingredients.enumerated() {
            let row = RecipeIngredient(context: ctx)
            row.id = UUID()
            row.recipePlan = plan
            row.displayName = ing.name
            row.canonicalIngredientSlug = ing.slug
            row.isOptional = ing.optional
            row.sortOrder = Int16(idx)
            row.amountText = ""
            row.source = "ai"
        }
        try ctx.save()
        return plan
    }

    @discardableResult
    private func makeSubstitutionEvent(
        for ingredient: RecipeIngredient,
        acceptedSwap: String?,
    ) throws -> SubstitutionEvent {
        let ctx = pc.viewContext
        let event = SubstitutionEvent(context: ctx)
        event.id = UUID()
        event.createdAt = Date()
        event.recipeIngredient = ingredient
        event.missingIngredientDisplayName = ingredient.displayName
        event.modelSuggestionText = acceptedSwap ?? ""
        if let swap = acceptedSwap {
            event.typedAcceptance = .accepted
            event.acceptedAlternativeText = swap
        } else {
            event.typedAcceptance = .rejected
            event.acceptedAlternativeText = nil
        }
        try ctx.save()
        return event
    }
}
