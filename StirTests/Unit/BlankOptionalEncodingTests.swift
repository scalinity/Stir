// BlankOptionalEncodingTests
//
// Locks the wire-shape contract that optional string fields are DROPPED
// (key absent), not encoded as "" (key present, value empty). Backend
// Zod validators declare these fields as `.string().min(1).optional()` —
// which accepts an absent key but REJECTS an empty string. Empty
// strings from Core Data defaults (e.g. `RecipeIngredient.amountText`
// has `defaultValueString=""`) would round-trip into the request body
// and trip VAL-01 server-side, surfacing as opaque AI-01 / "Find Swap"
// errors after the iOS dispatch's catch-all rewrites the error code.
//
// Three structs share this pattern today; one test file locks all of
// them so the next wire-shape struct that joins is reminded by example:
//   - SubstitutionRequest.MissingIngredient (commit 2ffbe90)
//   - GroceryGenerateRequest.Ingredient (commit e468fa4)
//   - GroceryGenerateRequest.PantryItemLite (commit e468fa4)

import XCTest
@testable import Stir

final class BlankOptionalEncodingTests: XCTestCase {
    private let encoder = JSONEncoder()

    // MARK: - GroceryGenerateRequest.Ingredient

    func test_groceryIngredient_dropsBlankCanonicalSlugAndAmountText() throws {
        let ing = GroceryGenerateRequest.Ingredient(
            displayName: "tomato",
            canonicalSlug: "",
            amountText: "",
        )
        let json = try jsonObject(from: ing)
        XCTAssertEqual(json["display_name"] as? String, "tomato")
        XCTAssertNil(json["canonical_slug"], "empty canonical_slug must be omitted")
        XCTAssertNil(json["amount_text"], "empty amount_text must be omitted")
    }

    func test_groceryIngredient_dropsWhitespaceOnlyOptionalFields() throws {
        let ing = GroceryGenerateRequest.Ingredient(
            displayName: "tomato",
            canonicalSlug: "   ",
            amountText: "\n\t ",
        )
        let json = try jsonObject(from: ing)
        XCTAssertNil(json["canonical_slug"], "whitespace-only canonical_slug must be omitted")
        XCTAssertNil(json["amount_text"], "whitespace-only amount_text must be omitted")
    }

    func test_groceryIngredient_dropsNilOptionalFields() throws {
        let ing = GroceryGenerateRequest.Ingredient(
            displayName: "tomato",
            canonicalSlug: nil,
            amountText: nil,
        )
        let json = try jsonObject(from: ing)
        XCTAssertNil(json["canonical_slug"])
        XCTAssertNil(json["amount_text"])
    }

    func test_groceryIngredient_keepsNonBlankOptionalFields() throws {
        let ing = GroceryGenerateRequest.Ingredient(
            displayName: "tomato",
            canonicalSlug: "tomato_red",
            amountText: "2 medium",
        )
        let json = try jsonObject(from: ing)
        XCTAssertEqual(json["canonical_slug"] as? String, "tomato_red")
        XCTAssertEqual(json["amount_text"] as? String, "2 medium")
    }

    // MARK: - GroceryGenerateRequest.PantryItemLite

    func test_pantryItemLite_dropsBlankCanonicalSlug() throws {
        let item = GroceryGenerateRequest.PantryItemLite(
            displayName: "olive oil",
            canonicalSlug: "",
        )
        let json = try jsonObject(from: item)
        XCTAssertEqual(json["display_name"] as? String, "olive oil")
        XCTAssertNil(json["canonical_slug"], "empty canonical_slug must be omitted")
    }

    func test_pantryItemLite_keepsNonBlankCanonicalSlug() throws {
        let item = GroceryGenerateRequest.PantryItemLite(
            displayName: "olive oil",
            canonicalSlug: "olive_oil",
        )
        let json = try jsonObject(from: item)
        XCTAssertEqual(json["canonical_slug"] as? String, "olive_oil")
    }

    // MARK: - SubstitutionRequest.MissingIngredient

    func test_missingIngredient_dropsBlankCanonicalSlugAndAmountText() throws {
        let ing = SubstitutionRequest.MissingIngredient(
            displayName: "garlic",
            canonicalSlug: "",
            amountText: "",
        )
        let json = try jsonObject(from: ing)
        XCTAssertEqual(json["display_name"] as? String, "garlic")
        XCTAssertNil(json["canonical_slug"])
        XCTAssertNil(json["amount_text"])
    }

    func test_missingIngredient_keepsNonBlankOptionalFields() throws {
        let ing = SubstitutionRequest.MissingIngredient(
            displayName: "garlic",
            canonicalSlug: "garlic",
            amountText: "3 cloves",
        )
        let json = try jsonObject(from: ing)
        XCTAssertEqual(json["canonical_slug"] as? String, "garlic")
        XCTAssertEqual(json["amount_text"] as? String, "3 cloves")
    }

    // MARK: - Helpers

    private func jsonObject<T: Encodable>(from value: T) throws -> [String: Any] {
        let data = try encoder.encode(value)
        let any = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = any as? [String: Any] else {
            XCTFail("expected JSON object, got \(any)")
            return [:]
        }
        return dict
    }
}
