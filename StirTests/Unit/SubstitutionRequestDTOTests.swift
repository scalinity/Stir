// SubstitutionRequestDTOTests
//
// Wire-format tests for SubstitutionRequest. Pins the empty-string-skip
// behavior of the three nested types (MissingIngredient,
// HouseholdContext.PantrySnapshotItem, RecipeContext.RemainingIngredient)
// so a future contributor can't regress the VAL-01 trapdoor that
// AIDispatchDTOs.swift fix(substitution) closed.
//
// Backend Zod is `.min(1).max(128).optional()` on `canonical_slug` and
// `amount_text`: an absent key is fine, an empty-string value is a 400.
// Swift's synthesized Encodable for `Optional<String>` calls
// `encodeIfPresent`, which DOES emit `""` when the property holds an
// empty string — that's the bug. The custom `encode(to:)` overrides
// trim and skip; these tests pin that.

import Foundation
import XCTest
@testable import Stir

@MainActor
final class SubstitutionRequestDTOTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    // MARK: - MissingIngredient

    func test_missingIngredient_emptyCanonicalSlug_isOmitted() throws {
        let mi = SubstitutionRequest.MissingIngredient(
            displayName: "dried pasta",
            canonicalSlug: "",
            amountText: "12 oz",
        )
        let json = try encodedJSON(mi)
        XCTAssertFalse(
            json.contains("\"canonical_slug\""),
            "empty canonical_slug must be omitted; got: \(json)",
        )
        XCTAssertTrue(json.contains("\"display_name\":\"dried pasta\""))
        XCTAssertTrue(json.contains("\"amount_text\":\"12 oz\""))
    }

    func test_missingIngredient_whitespaceCanonicalSlug_isOmitted() throws {
        let mi = SubstitutionRequest.MissingIngredient(
            displayName: "dried pasta",
            canonicalSlug: "  \n",
            amountText: nil,
        )
        let json = try encodedJSON(mi)
        XCTAssertFalse(
            json.contains("\"canonical_slug\""),
            "whitespace-only canonical_slug must be omitted; got: \(json)",
        )
        XCTAssertFalse(json.contains("\"amount_text\""))
    }

    func test_missingIngredient_emptyAmountText_isOmitted() throws {
        // Reproduces the production failure mode: RecipeIngredient.amountText
        // has Core Data defaultValueString="" so Gemini-omitted amounts flow
        // through as "" and trip backend Zod `.min(1).optional()`.
        let mi = SubstitutionRequest.MissingIngredient(
            displayName: "dried pasta",
            canonicalSlug: "pasta-dried",
            amountText: "",
        )
        let json = try encodedJSON(mi)
        XCTAssertFalse(
            json.contains("\"amount_text\""),
            "empty amount_text must be omitted; got: \(json)",
        )
        XCTAssertTrue(json.contains("\"canonical_slug\":\"pasta-dried\""))
    }

    func test_missingIngredient_nilOptionals_areOmitted() throws {
        let mi = SubstitutionRequest.MissingIngredient(
            displayName: "dried pasta",
            canonicalSlug: nil,
            amountText: nil,
        )
        let json = try encodedJSON(mi)
        XCTAssertFalse(json.contains("\"canonical_slug\""))
        XCTAssertFalse(json.contains("\"amount_text\""))
        XCTAssertTrue(json.contains("\"display_name\":\"dried pasta\""))
    }

    func test_missingIngredient_happyPath_emitsBothKeys() throws {
        let mi = SubstitutionRequest.MissingIngredient(
            displayName: "dried pasta",
            canonicalSlug: "pasta-dried",
            amountText: "12 oz",
        )
        let json = try encodedJSON(mi)
        XCTAssertTrue(json.contains("\"canonical_slug\":\"pasta-dried\""))
        XCTAssertTrue(json.contains("\"amount_text\":\"12 oz\""))
        XCTAssertTrue(json.contains("\"display_name\":\"dried pasta\""))
    }

    // MARK: - PantrySnapshotItem

    func test_pantrySnapshotItem_emptyCanonicalSlug_isOmitted() throws {
        // Reproduces the production failure mode: PantryItemRepository
        // writes `row.canonicalIngredientSlug = ing.canonicalSlug ?? ""`
        // for every scanned item without a slug, so the substitution
        // pantry_snapshot is the hot source of empty strings.
        let item = SubstitutionRequest.HouseholdContext.PantrySnapshotItem(
            displayName: "olive oil",
            canonicalSlug: "",
        )
        let json = try encodedJSON(item)
        XCTAssertFalse(
            json.contains("\"canonical_slug\""),
            "empty canonical_slug must be omitted; got: \(json)",
        )
        XCTAssertTrue(json.contains("\"display_name\":\"olive oil\""))
    }

    func test_pantrySnapshotItem_nilCanonicalSlug_isOmitted() throws {
        let item = SubstitutionRequest.HouseholdContext.PantrySnapshotItem(
            displayName: "olive oil",
            canonicalSlug: nil,
        )
        let json = try encodedJSON(item)
        XCTAssertFalse(json.contains("\"canonical_slug\""))
    }

    func test_pantrySnapshotItem_happyPath_emitsKey() throws {
        let item = SubstitutionRequest.HouseholdContext.PantrySnapshotItem(
            displayName: "olive oil",
            canonicalSlug: "olive-oil",
        )
        let json = try encodedJSON(item)
        XCTAssertTrue(json.contains("\"canonical_slug\":\"olive-oil\""))
        XCTAssertTrue(json.contains("\"display_name\":\"olive oil\""))
    }

    // MARK: - RemainingIngredient

    func test_remainingIngredient_emptyCanonicalSlug_isOmitted() throws {
        let item = SubstitutionRequest.RecipeContext.RemainingIngredient(
            displayName: "tomato",
            canonicalSlug: "",
        )
        let json = try encodedJSON(item)
        XCTAssertFalse(
            json.contains("\"canonical_slug\""),
            "empty canonical_slug must be omitted; got: \(json)",
        )
        XCTAssertTrue(json.contains("\"display_name\":\"tomato\""))
    }

    func test_remainingIngredient_happyPath_emitsKey() throws {
        let item = SubstitutionRequest.RecipeContext.RemainingIngredient(
            displayName: "tomato",
            canonicalSlug: "tomato",
        )
        let json = try encodedJSON(item)
        XCTAssertTrue(json.contains("\"canonical_slug\":\"tomato\""))
    }

    // MARK: - Helpers

    private func encodedJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
