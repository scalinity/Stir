// PantryItemDisplayExtensionsTests
//
// Coverage for the `isExpired` and `memoryStateLabel` helpers on
// `PantryItem+Extensions`. These are pure-functional helpers that
// drive the user-facing badge color in PantryRow — a regression in
// the preempt rule (`isExpired` overrides `typedMemoryState` so a
// `.remembered` row past `expiresAt` reads "Expired") would silently
// mislabel expired pantry items in production.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class PantryItemDisplayExtensionsTests: XCTestCase {
    private var pc: PersistenceController!
    private var household: HouseholdProfile!

    override func setUp() async throws {
        try await super.setUp()
        pc = PersistenceController(inMemory: true)
        let ctx = pc.viewContext
        household = HouseholdProfile(context: ctx)
        household.id = UUID()
        household.createdAt = Date()
        try ctx.save()
    }

    override func tearDown() async throws {
        pc = nil
        household = nil
        try await super.tearDown()
    }

    // MARK: - isExpired

    func test_isExpired_returnsFalseWhenExpiresAtIsNil() throws {
        let row = makeRow(expiresAt: nil, memoryState: .remembered)
        XCTAssertFalse(row.isExpired)
    }

    func test_isExpired_returnsTrueWhenExpiresAtInPast() throws {
        let row = makeRow(expiresAt: Date(timeIntervalSinceNow: -3600), memoryState: .remembered)
        XCTAssertTrue(row.isExpired)
    }

    func test_isExpired_returnsFalseWhenExpiresAtInFuture() throws {
        let row = makeRow(expiresAt: Date(timeIntervalSinceNow: 3600), memoryState: .remembered)
        XCTAssertFalse(row.isExpired)
    }

    // MARK: - memoryStateLabel

    func test_memoryStateLabel_pastExpiresAtPreemptsRemembered() throws {
        // The preempt rule: a .remembered row past its expiresAt reads
        // "Expired" rather than "Standing". This is the badge color
        // contract PantryRow relies on.
        let row = makeRow(
            expiresAt: Date(timeIntervalSinceNow: -3600),
            memoryState: .remembered,
        )
        XCTAssertEqual(row.memoryStateLabel, "Expired")
    }

    func test_memoryStateLabel_futureExpiresAtKeepsRemembered() throws {
        let row = makeRow(
            expiresAt: Date(timeIntervalSinceNow: 3600),
            memoryState: .remembered,
        )
        XCTAssertEqual(row.memoryStateLabel, "Standing")
    }

    func test_memoryStateLabel_ephemeralReadsToday() throws {
        let row = makeRow(expiresAt: nil, memoryState: .ephemeral)
        XCTAssertEqual(row.memoryStateLabel, "Today")
    }

    func test_memoryStateLabel_unknownReadsEmpty() throws {
        // The empty-string contract is load-bearing: PantryRow.stateBadge
        // gates rendering on `if !label.isEmpty`. If this changes,
        // .unknown rows would render an empty paper200 capsule.
        let row = makeRow(expiresAt: nil, memoryState: .unknown)
        XCTAssertEqual(row.memoryStateLabel, "")
    }

    func test_memoryStateLabel_expiredEnumReadsExpired() throws {
        // A row typed `.expired` with no `expiresAt` (legacy/inconsistent
        // data) still labels as "Expired" via the switch arm.
        let row = makeRow(expiresAt: nil, memoryState: .expired)
        XCTAssertEqual(row.memoryStateLabel, "Expired")
    }

    // MARK: - Helpers

    private func makeRow(
        expiresAt: Date?,
        memoryState: PantryItem.MemoryState,
    ) -> PantryItem {
        let row = PantryItem(context: pc.viewContext)
        row.id = UUID()
        row.household = household
        row.displayName = "test"
        row.canonicalIngredientSlug = ""
        row.typedSource = .manual
        row.typedMemoryState = memoryState
        row.userConfirmed = true
        row.confidence = 1.0
        row.createdAt = Date()
        row.updatedAt = Date()
        row.lastSeenAt = Date()
        row.expiresAt = expiresAt
        return row
    }
}
