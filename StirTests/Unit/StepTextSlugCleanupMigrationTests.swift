// StepTextSlugCleanupMigrationTests
//
// SCA-430 — unit tests for the per-install RecipeStep.instructionText
// cleanup migration. Two layers:
//
//   1. Pure-helper layer: `replaceEquipmentSlugs(in:)` is a static
//      `String → String` function, testable without a Core Data
//      fixture. Tests cover known slugs, multi-slug strings, word
//      boundaries, single-token-slug exclusion, and the no-match
//      identity path.
//   2. Service layer: `runIfNeeded()` against an in-memory
//      `PersistenceController`. Tests seed mixed dirty + clean
//      `RecipeStep` rows, run the migration, and assert (a) dirty
//      rows are rewritten, (b) clean rows are untouched, (c) the
//      UserDefaults gate flag is set, (d) a second `runIfNeeded`
//      call is a no-op, (e) telemetry fires with the right counts.
//
// Mirrors `PantryTombstoneReaperTests`' UserDefaults-suite isolation
// pattern so tests in this file don't bleed gate state across
// invocations (`UserDefaults(suiteName: "test.…<UUID>")`).

import CoreData
import XCTest
@testable import Stir

@MainActor
final class StepTextSlugCleanupMigrationTests: XCTestCase {
    private var pc: PersistenceController!
    private var household: HouseholdProfile!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        pc = PersistenceController(inMemory: true)
        let ctx = pc.viewContext
        household = HouseholdProfile(context: ctx)
        household.id = UUID()
        household.createdAt = Date()
        try ctx.save()
        suiteName = "test.step_text_slug_cleanup.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        household = nil
        pc = nil
        try await super.tearDown()
    }

    // MARK: - Pure helper

    func test_replaceEquipmentSlugs_replacesKnownMultiTokenSlug() {
        XCTAssertEqual(
            StepTextSlugCleanupMigration.replaceEquipmentSlugs(in: "In the food_processor, pulse flour."),
            "In the food processor, pulse flour.",
        )
    }

    func test_replaceEquipmentSlugs_replacesMultipleSlugsInOneString() {
        XCTAssertEqual(
            StepTextSlugCleanupMigration.replaceEquipmentSlugs(
                in: "Use the food_processor or stand_mixer to combine.",
            ),
            "Use the food processor or stand mixer to combine.",
        )
    }

    func test_replaceEquipmentSlugs_replacesEverySupportedSlug() {
        let pairs: [(slug: String, display: String)] = [
            ("food_processor", "food processor"),
            ("air_fryer", "air fryer"),
            ("instant_pot", "Instant Pot"),
            ("slow_cooker", "slow cooker"),
            ("stand_mixer", "stand mixer"),
            ("rice_cooker", "rice cooker"),
            ("cast_iron", "cast iron pan"),
            ("nonstick_pan", "nonstick pan"),
            ("sheet_pan", "sheet pan"),
            ("dutch_oven", "Dutch oven"),
        ]
        // Proper nouns (Dutch oven, Instant Pot) keep their casing
        // mid-sentence; common-noun phrases lowercase the first word.
        // The expected `display` value in each tuple above is the
        // final rendered form, no `.lowercased()` blanket transform.
        for (slug, display) in pairs {
            let input = "Place into the \(slug) and cook."
            let expected = "Place into the \(display) and cook."
            XCTAssertEqual(
                StepTextSlugCleanupMigration.replaceEquipmentSlugs(in: input),
                expected,
                "Slug `\(slug)` did not rewrite cleanly",
            )
        }
    }

    func test_replaceEquipmentSlugs_doesNotMatchInsideLongerToken() {
        // Word-boundary regex must NOT match `food_processor` embedded
        // inside `non_food_processor`. Underscore is a word character
        // in NSRegularExpression `\b`, so the boundary check on the
        // left edge holds. Asserting belt-and-suspenders against
        // accidental over-match.
        XCTAssertEqual(
            StepTextSlugCleanupMigration.replaceEquipmentSlugs(in: "Use a non_food_processor blade."),
            "Use a non_food_processor blade.",
        )
    }

    func test_replaceEquipmentSlugs_doesNotMatchSingleTokenSlugs() {
        // `oven`, `grill`, `blender`, etc. are valid English words
        // and would false-positive on natural prose. The
        // underscore-presence gate in the helper must exclude them.
        XCTAssertEqual(
            StepTextSlugCleanupMigration.replaceEquipmentSlugs(in: "Preheat the oven to 425."),
            "Preheat the oven to 425.",
        )
        XCTAssertEqual(
            StepTextSlugCleanupMigration.replaceEquipmentSlugs(in: "Grill the chicken for 8 minutes."),
            "Grill the chicken for 8 minutes.",
        )
    }

    func test_replaceEquipmentSlugs_returnsIdentityOnNoMatch() {
        let clean = "In the food processor, pulse flour."
        XCTAssertEqual(
            StepTextSlugCleanupMigration.replaceEquipmentSlugs(in: clean),
            clean,
        )
    }

    func test_replaceEquipmentSlugs_passesEmptyStringThrough() {
        XCTAssertEqual(
            StepTextSlugCleanupMigration.replaceEquipmentSlugs(in: ""),
            "",
        )
    }

    // MARK: - Service layer

    func test_runIfNeeded_rewritesDirtyRows_leavesCleanRowsAlone() async throws {
        let plan = makeRecipePlan(stepTexts: [
            "In the food_processor, pulse flour.",
            "Pour into the dutch_oven.",
            "Bake at 425 until golden.",
            "Serve with a side salad.",
        ])
        try pc.viewContext.save()

        let collector = TelemetryCollector()
        let migration = makeMigration(captures: collector)

        let result = await migration.runIfNeeded()
        XCTAssertEqual(result?.stepsScanned, 4)
        XCTAssertEqual(result?.stepsUpdated, 2)
        XCTAssertEqual(collector.captures.count, 1)
        XCTAssertEqual(collector.captures.first?.scanned, 4)
        XCTAssertEqual(collector.captures.first?.updated, 2)

        // Re-read rows from a fresh context to confirm CloudKit-bound
        // writes actually landed (vs. the in-memory bg context only).
        let bg = pc.container.newBackgroundContext()
        let texts = try await bg.perform { [planID = plan.objectID] () -> [String] in
            let refreshed = bg.object(with: planID) as? RecipePlan
            return refreshed?.stepArray.compactMap(\.instructionText) ?? []
        }
        XCTAssertEqual(
            texts.sorted(),
            [
                "Bake at 425 until golden.",
                "In the food processor, pulse flour.",
                "Pour into the Dutch oven.",
                "Serve with a side salad.",
            ].sorted(),
        )
    }

    func test_runIfNeeded_setsFlagOnSuccess() async throws {
        _ = makeRecipePlan(stepTexts: ["In the food_processor, pulse."])
        try pc.viewContext.save()

        let migration = makeMigration(captures: TelemetryCollector())
        XCTAssertFalse(migration.hasRun)
        _ = await migration.runIfNeeded()
        XCTAssertTrue(migration.hasRun)
    }

    func test_runIfNeeded_secondCallIsNoOp() async throws {
        _ = makeRecipePlan(stepTexts: ["In the food_processor, pulse."])
        try pc.viewContext.save()

        let collector = TelemetryCollector()
        let migration = makeMigration(captures: collector)
        _ = await migration.runIfNeeded()
        XCTAssertEqual(collector.captures.count, 1)

        let second = await migration.runIfNeeded()
        XCTAssertNil(second, "Second call must short-circuit on the flag, returning nil")
        XCTAssertEqual(collector.captures.count, 1, "No telemetry on the gated call")
    }

    func test_runIfNeeded_emitsZeroUpdatedOnAllCleanStore() async throws {
        _ = makeRecipePlan(stepTexts: [
            "Preheat the oven.",
            "Combine in a bowl.",
        ])
        try pc.viewContext.save()

        let collector = TelemetryCollector()
        let migration = makeMigration(captures: collector)
        let result = await migration.runIfNeeded()
        XCTAssertEqual(result?.stepsScanned, 2)
        XCTAssertEqual(result?.stepsUpdated, 0)
        // SCA-430: telemetry fires even on zero-row passes so the
        // funnel sees a continuous time-series — same posture as
        // PantryTombstoneReaper. Missing emissions across the install
        // base would flag a wiring regression.
        XCTAssertEqual(collector.captures.count, 1)
    }

    func test_reset_clearsFlag() async throws {
        _ = makeRecipePlan(stepTexts: ["In the food_processor."])
        try pc.viewContext.save()

        let migration = makeMigration(captures: TelemetryCollector())
        _ = await migration.runIfNeeded()
        XCTAssertTrue(migration.hasRun)
        migration.reset()
        XCTAssertFalse(migration.hasRun)
    }

    // MARK: - Helpers

    private func makeMigration(captures: TelemetryCollector) -> StepTextSlugCleanupMigration {
        StepTextSlugCleanupMigration(
            controller: pc,
            defaults: defaults,
            telemetry: { scanned, updated in
                captures.append((scanned: scanned, updated: updated))
            },
        )
    }

    @discardableResult
    private func makeRecipePlan(stepTexts: [String]) -> RecipePlan {
        let ctx = pc.viewContext
        let plan = RecipePlan(context: ctx)
        plan.id = UUID()
        plan.title = "Test Plan"
        plan.createdAt = Date()
        plan.household = household
        for (index, text) in stepTexts.enumerated() {
            let step = RecipeStep(context: ctx)
            step.id = UUID()
            step.stepNumber = Int16(index + 1)
            step.instructionText = text
            step.recipePlan = plan
        }
        return plan
    }
}

@MainActor
private final class TelemetryCollector {
    private(set) var captures: [(scanned: Int, updated: Int)] = []

    func append(_ event: (scanned: Int, updated: Int)) {
        captures.append(event)
    }
}
