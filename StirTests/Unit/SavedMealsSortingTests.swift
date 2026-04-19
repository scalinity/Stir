// SavedMealsSortingTests
//
// Exercises CookingSessionRepository.sortByLastCooked. The repo's
// savedMealEntries(for:) builds [SavedMealEntry] then sorts them
// last-cooked-desc with un-cooked rows pushed to the bottom and a
// deterministic alphabetical fallback for the un-cooked tail. The
// closure was originally inlined; step-4 testability fix extracted it
// as a static so the comparator can be exercised without round-tripping
// through Core Data.

import Foundation
import XCTest
@testable import Stir

final class SavedMealsSortingTests: XCTestCase {
    private typealias Entry = CookingSessionRepository.SavedMealEntry

    func test_sort_putsMoreRecentlyCookedFirst() {
        let now = Date()
        let older = makeEntry(title: "Older", lastCookedAt: now.addingTimeInterval(-3600))
        let newer = makeEntry(title: "Newer", lastCookedAt: now)

        let sorted = [older, newer].sorted(by: CookingSessionRepository.sortByLastCooked)
        XCTAssertEqual(sorted.map(\.title), ["Newer", "Older"])
    }

    func test_sort_pushesUncookedEntriesBelowCookedEntries() {
        let cooked = makeEntry(title: "Cooked", lastCookedAt: Date())
        let uncooked = makeEntry(title: "Untouched", lastCookedAt: nil)

        let sorted = [uncooked, cooked].sorted(by: CookingSessionRepository.sortByLastCooked)
        XCTAssertEqual(sorted.map(\.title), ["Cooked", "Untouched"])
    }

    func test_sort_amongUncookedEntriesFallsBackToAlphabeticalTitle() {
        let zebra = makeEntry(title: "Zebra Stew", lastCookedAt: nil)
        let apple = makeEntry(title: "Apple Pie", lastCookedAt: nil)
        let middle = makeEntry(title: "Mango Salsa", lastCookedAt: nil)

        let sorted = [zebra, middle, apple].sorted(by: CookingSessionRepository.sortByLastCooked)
        XCTAssertEqual(sorted.map(\.title), ["Apple Pie", "Mango Salsa", "Zebra Stew"])
    }

    func test_sort_preservesDeterminismWithMixedEntries() {
        // 5 entries: 3 cooked at distinct times, 2 uncooked.
        let now = Date()
        let mostRecent = makeEntry(title: "Most recent", lastCookedAt: now)
        let middle = makeEntry(title: "Middle", lastCookedAt: now.addingTimeInterval(-600))
        let earliest = makeEntry(title: "Earliest", lastCookedAt: now.addingTimeInterval(-7200))
        let untriedB = makeEntry(title: "Beta untried", lastCookedAt: nil)
        let untriedA = makeEntry(title: "Alpha untried", lastCookedAt: nil)

        let sorted = [middle, untriedB, mostRecent, untriedA, earliest]
            .sorted(by: CookingSessionRepository.sortByLastCooked)

        XCTAssertEqual(sorted.map(\.title), [
            "Most recent",
            "Middle",
            "Earliest",
            "Alpha untried",
            "Beta untried",
        ])
    }

    func test_sort_isStableForEntriesWithEqualLastCookedDates() {
        // Two cooked entries sharing the same timestamp — comparator
        // returns `l > r`, which is `false` for equality. Swift's sort
        // is stable, so input order must be preserved.
        let stamp = Date()
        let first = makeEntry(title: "First", lastCookedAt: stamp)
        let second = makeEntry(title: "Second", lastCookedAt: stamp)

        let sorted = [first, second].sorted(by: CookingSessionRepository.sortByLastCooked)
        XCTAssertEqual(sorted.map(\.title), ["First", "Second"])

        let reverseSorted = [second, first].sorted(by: CookingSessionRepository.sortByLastCooked)
        XCTAssertEqual(reverseSorted.map(\.title), ["Second", "First"])
    }

    private func makeEntry(title: String, lastCookedAt: Date?, rating: Int? = nil) -> Entry {
        Entry(
            id: UUID(),
            title: title,
            plan: nil,
            lastCookedAt: lastCookedAt,
            rating: rating,
        )
    }
}
