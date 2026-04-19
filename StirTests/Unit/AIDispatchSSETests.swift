// AIDispatchSSETests
//
// Exercises the pure SSE event decoder without spinning up URLSession
// or hitting a live Gemini endpoint. Covers the three event types
// (dish / error / done) plus the forward-compat "ignore unknown"
// branch.

import XCTest
@testable import Stir

final class AIDispatchSSETests: XCTestCase {
    func test_dishEvent_decodesToDishCard() throws {
        let json = """
        {"rank":1,"title":"Tomato pasta","total_time_minutes":22,\
        "why_it_fits":"fast + uses pantry tomatoes",\
        "missing_ingredient_count":1,"fit_label_primary":"fastest",\
        "fit_label_secondary":null,"hard_constraint_pass":true,\
        "recipe_plan":{"servings":2,"difficulty":2,"cuisine":null,\
        "ingredients":[{"display_name":"tomato","canonical_slug":"tomato",\
        "amount_text":"2 cups","is_optional":false}],\
        "steps":[{"step_number":1,"instruction_text":"Boil pasta.",\
        "timer_seconds":600,"caution_tags":[]}]},\
        "reasoning_summary":"Balances speed and pantry coverage. Simple weeknight win."}
        """
        let evt = try decodeSSEEvent(event: "dish", dataJSON: json)
        guard case .dish(let card) = evt else {
            XCTFail("expected .dish event")
            return
        }
        XCTAssertEqual(card.rank, 1)
        XCTAssertEqual(card.title, "Tomato pasta")
        XCTAssertEqual(card.totalTimeMinutes, 22)
        XCTAssertEqual(card.recipePlan.ingredients.count, 1)
        XCTAssertEqual(card.recipePlan.steps.first?.timerSeconds, 600)
        XCTAssertTrue(card.hardConstraintPass)
    }

    func test_errorEvent_decodesToSlotError() throws {
        let evt = try decodeSSEEvent(
            event: "error",
            dataJSON: #"{"rank":2,"code":"AI-02"}"#,
        )
        guard case .slotError(let rank, let code) = evt else {
            XCTFail("expected .slotError event")
            return
        }
        XCTAssertEqual(rank, 2)
        XCTAssertEqual(code, "AI-02")
    }

    func test_doneEvent_decodesFinalMetadata() throws {
        let id = UUID()
        let json = """
        {"solve_request_id":"\(id.uuidString)","total_cost_usd":0.00412,\
        "dishes_returned":2,"retry_count":1,"prompt_version":"1.0.0"}
        """
        let evt = try decodeSSEEvent(event: "done", dataJSON: json)
        guard case .done(let sid, let cost, let returned, let retry, let version) = evt else {
            XCTFail("expected .done event")
            return
        }
        XCTAssertEqual(sid, id)
        XCTAssertEqual(cost, 0.00412, accuracy: 1e-7)
        XCTAssertEqual(returned, 2)
        XCTAssertEqual(retry, 1)
        XCTAssertEqual(version, "1.0.0")
    }

    func test_unknownEvent_returnsNilForForwardCompat() throws {
        let evt = try decodeSSEEvent(event: "future_v2", dataJSON: "{}")
        XCTAssertNil(evt, "unknown events should be ignored, not throw")
    }

    func test_dishEventWithFitLabelSecondary() throws {
        let json = """
        {"rank":3,"title":"Salad","total_time_minutes":10,\
        "why_it_fits":"Quick + light","missing_ingredient_count":0,\
        "fit_label_primary":"uses_what_you_have","fit_label_secondary":"new_to_you",\
        "hard_constraint_pass":true,\
        "recipe_plan":{"servings":2,"difficulty":1,"cuisine":"Mediterranean",\
        "ingredients":[{"display_name":"greens","canonical_slug":null,\
        "amount_text":"1 bag","is_optional":false}],\
        "steps":[{"step_number":1,"instruction_text":"Toss.","timer_seconds":null,"caution_tags":["knife"]}]},\
        "reasoning_summary":"Everything is in the fridge already."}
        """
        let evt = try decodeSSEEvent(event: "dish", dataJSON: json)
        guard case .dish(let card) = evt else { return XCTFail("expected .dish") }
        XCTAssertEqual(card.fitLabelSecondary, "new_to_you")
        XCTAssertEqual(card.recipePlan.cuisine, "Mediterranean")
        XCTAssertEqual(card.recipePlan.steps.first?.cautionTags?.first, "knife")
    }

    func test_dishEvent_rejectsInvalidEnum() throws {
        let badJson = """
        {"rank":1,"title":"Test","total_time_minutes":20,"why_it_fits":"x",\
        "missing_ingredient_count":0,"fit_label_primary":"NOT_A_VALID_LABEL",\
        "hard_constraint_pass":true,\
        "recipe_plan":{"servings":2,"difficulty":2,"ingredients":[],"steps":[]},\
        "reasoning_summary":"y"}
        """
        // Our DishCard schema doesn't constrain fit_label_primary at decode
        // time (backend schema does). Defensive: the iOS client trusts the
        // wire but doesn't explode — the raw string flows through.
        let evt = try decodeSSEEvent(event: "dish", dataJSON: badJson)
        guard case .dish(let card) = evt else { return XCTFail("expected .dish") }
        XCTAssertEqual(card.fitLabelPrimary, "NOT_A_VALID_LABEL")
    }
}
