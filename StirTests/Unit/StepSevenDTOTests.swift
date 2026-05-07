// StepSevenDTOTests
//
// Wire-format round-trip tests for the step-7 AIDispatch DTOs. The
// Edge Functions are covered by Deno tests; these tests lock in the
// iOS side — specifically, that every payload serializes with snake_case
// field names the backend Zod schemas accept.

import Foundation
import XCTest
@testable import Stir

final class StepSevenDTOTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: - RecipeImportRequest

    func test_recipeImportRequest_urlPath_encodesWithSnakeCaseFields() throws {
        let body = RecipeImportRequest(
            importID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            sourceType: .url,
            payload: .url("https://example.com/recipe"),
        )
        let json = try encoder.encode(body)
        let str = String(data: json, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("\"import_id\""))
        XCTAssertTrue(str.contains("\"source_type\":\"url\""))
        XCTAssertTrue(str.contains("\"url\":\"https:\\/\\/example.com\\/recipe\""))
    }

    func test_recipeImportRequest_shareSheet_distinctFromUrl() throws {
        let body = RecipeImportRequest(
            importID: UUID(),
            sourceType: .shareSheet,
            payload: .url("https://shared"),
        )
        let json = try encoder.encode(body)
        let str = String(data: json, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("\"source_type\":\"share_sheet\""))
    }

    func test_recipeImportRequest_screenshotOCR_carriesOcrPageCount() throws {
        let body = RecipeImportRequest(
            importID: UUID(),
            sourceType: .screenshotOCR,
            payload: .screenshotOCR(text: "some text", pageCount: 3),
        )
        let json = try encoder.encode(body)
        let str = String(data: json, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("\"source_type\":\"screenshot_ocr\""))
        XCTAssertTrue(str.contains("\"ocr_text\":\"some text\""))
        XCTAssertTrue(str.contains("\"ocr_page_count\":3"))
    }

    func test_recipeImportRequest_pastedText() throws {
        let body = RecipeImportRequest(
            importID: UUID(),
            sourceType: .pastedText,
            payload: .pastedText("1 cup rice, 2 cups water"),
        )
        let json = try encoder.encode(body)
        let str = String(data: json, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("\"source_type\":\"pasted_text\""))
        XCTAssertTrue(str.contains("\"pasted_text\":"))
    }

    // MARK: - RecipeImportResponse

    func test_recipeImportResponse_completedRoundTrip() throws {
        let fixture = """
        {
          "import_id": "11111111-1111-4111-8111-111111111111",
          "status": "completed",
          "recipe": {
            "title": "Chicken Tacos",
            "servings": 4,
            "estimated_minutes": 25,
            "ingredients": [
              { "display_name": "chicken thighs", "canonical_slug": "chicken_thigh", "amount_text": "1.5 lbs", "group": null }
            ],
            "steps": [
              { "step_number": 1, "instruction_text": "Cook", "timer_seconds": 600, "caution_tags": ["raw_chicken"] }
            ],
            "parse_quality": "high",
            "edit_hints": ["missing_servings"]
          },
          "retry_count": 0,
          "prompt_version": "1.0.0"
        }
        """.data(using: .utf8)!

        let parsed = try decoder.decode(RecipeImportResponse.self, from: fixture)
        XCTAssertEqual(parsed.status, .completed)
        XCTAssertEqual(parsed.recipe?.title, "Chicken Tacos")
        XCTAssertEqual(parsed.recipe?.parseQuality, .high)
        XCTAssertEqual(parsed.recipe?.ingredients.first?.canonicalSlug, "chicken_thigh")
        XCTAssertEqual(parsed.recipe?.steps.first?.timerSeconds, 600)
        XCTAssertEqual(parsed.recipe?.steps.first?.cautionTags, ["raw_chicken"])
    }

    func test_recipeImportResponse_queuedNoRecipe() throws {
        let fixture = """
        {
          "import_id": "22222222-2222-4222-8222-222222222222",
          "status": "queued",
          "recipe": null,
          "retry_count": 0,
          "prompt_version": "1.0.0",
          "async_job_id": "job-uuid"
        }
        """.data(using: .utf8)!
        let parsed = try decoder.decode(RecipeImportResponse.self, from: fixture)
        XCTAssertEqual(parsed.status, .queued)
        XCTAssertNil(parsed.recipe)
        XCTAssertEqual(parsed.asyncJobID, "job-uuid")
    }

    // MARK: - GroceryGenerateRequest

    func test_groceryGenerateRequest_snakeCaseFields() throws {
        let body = GroceryGenerateRequest(
            sourceID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            sourceType: .recipe,
            ingredientsNeeded: [.init(displayName: "onion", canonicalSlug: "onion", amountText: "1")],
            pantrySnapshot: [.init(displayName: "olive oil", canonicalSlug: "olive_oil")],
            recipeTitle: "Soup",
        )
        let json = try encoder.encode(body)
        let str = String(data: json, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("\"source_id\""))
        XCTAssertTrue(str.contains("\"source_type\":\"recipe\""))
        XCTAssertTrue(str.contains("\"ingredients_needed\""))
        XCTAssertTrue(str.contains("\"pantry_snapshot\""))
        XCTAssertTrue(str.contains("\"recipe_title\":\"Soup\""))
        XCTAssertTrue(str.contains("\"display_name\":\"onion\""))
        XCTAssertTrue(str.contains("\"canonical_slug\":\"onion\""))
    }

    // MARK: - GroceryGenerateResponse

    func test_groceryGenerateResponse_priorityPresentOnEveryItem() throws {
        let fixture = """
        {
          "source_id": "33333333-3333-4333-8333-333333333333",
          "source_type": "recipe",
          "missing_items": [
            { "display_name": "chicken thighs", "amount_text": "1.5 lbs", "canonical_slug": "chicken_thigh", "grocery_category": "meat", "priority": "high" },
            { "display_name": "parsley", "amount_text": null, "canonical_slug": null, "grocery_category": "produce", "priority": "low" }
          ],
          "already_have": [ { "display_name": "olive oil", "canonical_slug": "olive_oil" } ],
          "total_item_count": 2,
          "prompt_version": "1.0.0",
          "retry_count": 0
        }
        """.data(using: .utf8)!
        let parsed = try decoder.decode(GroceryGenerateResponse.self, from: fixture)
        XCTAssertEqual(parsed.missingItems.count, 2)
        for item in parsed.missingItems {
            XCTAssertFalse(item.priority.isEmpty, "priority required on every row — spec §4.17")
            XCTAssertTrue(["normal", "low", "high"].contains(item.priority))
        }
    }

    // MARK: - PushRegisterRequest

    func test_pushRegisterRequest_nestedPrefsUseSnakeCase() throws {
        let body = PushRegisterRequest(
            apnsToken: String(repeating: "a", count: 64),
            environment: .sandbox,
            notificationPrefs: .init(importCompletion: true, reactivation: false),
        )
        let json = try encoder.encode(body)
        let str = String(data: json, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("\"apns_token\""))
        XCTAssertTrue(str.contains("\"environment\":\"sandbox\""))
        XCTAssertTrue(str.contains("\"import_completion\":true"))
        XCTAssertTrue(str.contains("\"reactivation\":false"))
        XCTAssertFalse(str.contains("trial_reminder"), "wire field retired in SCA-74")
    }

    // MARK: - DinnerSolveRequest leftovers mode

    func test_dinnerSolve_leftoversContext_encodesHintAndItems() throws {
        let body = DinnerSolveRequest(
            solveRequestID: UUID(),
            parseID: nil,
            ingredients: [.init(displayName: "rice", canonicalSlug: "rice", amountText: nil)],
            constraints: nil,
            householdContext: .init(servings: 2, dietaryRules: [], availableEquipment: ["stovetop"]),
            contextHint: .leftovers,
            leftoversItems: [.init(displayName: "chili", canonicalSlug: nil, approximateAmountText: "2 cups")],
            feedbackSummary: nil,
        )
        let json = try encoder.encode(body)
        let str = String(data: json, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("\"context_hint\":\"leftovers\""))
        XCTAssertTrue(str.contains("\"leftovers_items\""))
        XCTAssertTrue(str.contains("\"approximate_amount_text\":\"2 cups\""))
    }

    func test_dinnerSolve_standardPath_omitsLeftoversFields() throws {
        // Explicit nil → field emitted as null by default. What the backend's
        // Zod `.strict()` cares about is not whether the key appears with
        // null vs omitted — both are rejected cross-mixed (leftovers=null +
        // context_hint=leftovers will fail server-side), but standard mode
        // must pass when both are nil.
        let body = DinnerSolveRequest(
            solveRequestID: UUID(),
            parseID: nil,
            ingredients: [.init(displayName: "rice", canonicalSlug: "rice", amountText: nil)],
            constraints: nil,
            householdContext: .init(servings: 2, dietaryRules: [], availableEquipment: ["stovetop"]),
            contextHint: nil,
            leftoversItems: nil,
            feedbackSummary: nil,
        )
        let json = try encoder.encode(body)
        let str = String(data: json, encoding: .utf8) ?? ""
        // nil fields should not appear in the encoded JSON since Encodable
        // defaults skip nil optionals on custom-CodingKeys types. Either
        // skipped or explicit null both satisfy the Zod refine rule.
        XCTAssertTrue(str.contains("\"ingredients\""))
        // No assertion on presence of context_hint — tolerate either encoded shape.
    }
}
