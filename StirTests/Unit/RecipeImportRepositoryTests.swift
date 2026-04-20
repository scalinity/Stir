// RecipeImportRepositoryTests
//
// Spec §4.10 — every import attempt persists a row regardless of
// success/failure. These tests assert the full state machine:
//   pending → processing → completed (with recipePlanId + aiRequestId)
//   pending → failed (with errorCode)
//   pending → failed (USER_CANCELLED on Import Review back-out)
// Plus the 30-day retention purge and the SHA-256 rawTextHash.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class RecipeImportRepositoryTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var repo: RecipeImportRepository!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        let houseRepo = HouseholdProfileRepository(controller: controller)
        household = try houseRepo.ensureHouseholdProfile(for: "install:test-\(UUID().uuidString)")
        repo = RecipeImportRepository(controller: controller)
    }

    // MARK: - Start

    func test_start_writesPendingRowWithSHA256Hash() throws {
        let id = UUID()
        let row = try repo.start(for: household, input: .init(
            importID: id,
            source: .url,
            sourceURL: "https://example.com/recipe",
            ocrPageCount: 0,
            rawContent: "Chicken & rice",
        ))

        XCTAssertEqual(row.id, id)
        XCTAssertEqual(row.source, .url)
        XCTAssertEqual(row.statusEnum, .pending)
        XCTAssertEqual(row.sourceURL, "https://example.com/recipe")
        XCTAssertEqual(row.ocrPageCount, 0)
        XCTAssertNil(row.completedAt)
        XCTAssertNotNil(row.submittedAt)
        // SHA-256 of "Chicken & rice"
        XCTAssertEqual(row.rawTextHash?.count, 64, "SHA-256 hex digest should be 64 chars")
        XCTAssertFalse(row.rawTextHash?.contains("Chicken") == true, "raw content should NOT be stored verbatim")
    }

    func test_start_discriminatesAllFourSources() throws {
        for source in RecipeImportSource.allCases {
            let row = try repo.start(for: household, input: .init(
                importID: UUID(),
                source: source,
                sourceURL: source == .url || source == .shareSheet ? "https://example.com" : nil,
                ocrPageCount: source == .screenshotOCR ? 2 : 0,
                rawContent: "x",
            ))
            XCTAssertEqual(row.source, source, "source should round-trip for \(source.rawValue)")
        }
    }

    // MARK: - markCompleted

    func test_markCompleted_linksRecipePlanIdAndAiRequestId() throws {
        let id = UUID()
        let row = try repo.start(for: household, input: .init(
            importID: id, source: .pastedText, sourceURL: nil, ocrPageCount: 0, rawContent: "pasted",
        ))
        let planID = UUID()

        try repo.markCompleted(row, recipePlanID: planID, aiRequestID: "req-abc")

        XCTAssertEqual(row.statusEnum, .completed)
        XCTAssertEqual(row.recipePlanId, planID)
        XCTAssertEqual(row.aiRequestId, "req-abc")
        XCTAssertNotNil(row.completedAt)
    }

    // MARK: - markFailed

    func test_markFailed_withImport01Code() throws {
        let row = try repo.start(for: household, input: .init(
            importID: UUID(), source: .url, sourceURL: "https://bad.url", ocrPageCount: 0, rawContent: "x",
        ))

        try repo.markFailed(row, errorCode: RecipeImportErrorCode.importFailed)

        XCTAssertEqual(row.statusEnum, .failed)
        XCTAssertEqual(row.errorCode, "IMPORT-01")
        XCTAssertNotNil(row.completedAt, "completedAt populated on failure too — marks the attempt as finished")
        XCTAssertNil(row.recipePlanId, "no recipe plan created on failure")
    }

    func test_markFailed_userCancelledFromImportReview() throws {
        let row = try repo.start(for: household, input: .init(
            importID: UUID(), source: .shareSheet, sourceURL: "https://shared.url", ocrPageCount: 0, rawContent: "x",
        ))

        try repo.markFailed(row, errorCode: RecipeImportErrorCode.userCancelled)

        XCTAssertEqual(row.statusEnum, .failed)
        XCTAssertEqual(row.errorCode, "USER_CANCELLED")
    }

    // MARK: - find / recent

    func test_find_returnsPersistedRow() throws {
        let id = UUID()
        _ = try repo.start(for: household, input: .init(
            importID: id, source: .url, sourceURL: "https://example.com", ocrPageCount: 0, rawContent: "x",
        ))
        let found = try repo.find(importID: id)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, id)
    }

    func test_recent_returnsInDescendingSubmittedAtOrder() throws {
        let first = try repo.start(for: household, input: .init(
            importID: UUID(), source: .url, sourceURL: "https://first", ocrPageCount: 0, rawContent: "first",
        ))
        // Force distinct timestamps to guard against sub-millisecond ordering ties.
        first.submittedAt = Date(timeIntervalSince1970: 1_000_000)
        let second = try repo.start(for: household, input: .init(
            importID: UUID(), source: .url, sourceURL: "https://second", ocrPageCount: 0, rawContent: "second",
        ))
        second.submittedAt = Date(timeIntervalSince1970: 1_000_100)
        try controller.save()

        let recent = try repo.recent(for: household, limit: 10)

        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent.first?.id, second.id, "newer row first")
        XCTAssertEqual(recent.last?.id, first.id, "older row last")
    }

    // MARK: - Retention

    func test_purgeExpired_removesCompletedRowsOlderThan30Days() throws {
        // 1. Completed 40 days ago — should be purged.
        let old = try repo.start(for: household, input: .init(
            importID: UUID(), source: .url, sourceURL: "https://old", ocrPageCount: 0, rawContent: "x",
        ))
        try repo.markCompleted(old, recipePlanID: UUID(), aiRequestID: nil)
        old.completedAt = Date().addingTimeInterval(-40 * 86_400)

        // 2. Completed 10 days ago — should be kept.
        let recent = try repo.start(for: household, input: .init(
            importID: UUID(), source: .url, sourceURL: "https://recent", ocrPageCount: 0, rawContent: "x",
        ))
        try repo.markCompleted(recent, recipePlanID: UUID(), aiRequestID: nil)
        recent.completedAt = Date().addingTimeInterval(-10 * 86_400)

        // 3. Failed 40 days ago — should be kept (audit trail for failures
        //    is retained regardless of age; only successful-link rows purge).
        let failedOld = try repo.start(for: household, input: .init(
            importID: UUID(), source: .url, sourceURL: "https://failed-old", ocrPageCount: 0, rawContent: "x",
        ))
        try repo.markFailed(failedOld, errorCode: "IMPORT-01")
        failedOld.completedAt = Date().addingTimeInterval(-40 * 86_400)

        try controller.save()

        let purged = try repo.purgeExpired(olderThan: 30)

        XCTAssertEqual(purged, 1, "only the 40-day-old completed row should purge")

        // Verify remaining rows.
        let all = try repo.recent(for: household, limit: 10)
        let ids = Set(all.compactMap { $0.id })
        XCTAssertTrue(ids.contains(recent.id ?? UUID()))
        XCTAssertTrue(ids.contains(failedOld.id ?? UUID()))
        XCTAssertFalse(ids.contains(old.id ?? UUID()))
    }

    // MARK: - SHA-256

    func test_sha256Hex_isDeterministic() {
        let a = RecipeImportRepository.sha256Hex("chicken & rice")
        let b = RecipeImportRepository.sha256Hex("chicken & rice")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
    }

    func test_sha256Hex_differsOnDifferentInputs() {
        let a = RecipeImportRepository.sha256Hex("chicken & rice")
        let b = RecipeImportRepository.sha256Hex("chicken and rice")
        XCTAssertNotEqual(a, b)
    }
}
