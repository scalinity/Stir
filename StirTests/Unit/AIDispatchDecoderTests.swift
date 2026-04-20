// AIDispatchDecoderTests
//
// Regression tests for the two dinner-solve decode bugs fixed in this
// session's chain:
//
//   1. `URLSession.AsyncBytes.lines` silently skipped consecutive
//      newlines, which collapsed every SSE event's `data:` payload
//      into one buffer and reassigned `currentEvent` to `done`. Fix:
//      byte-level `SSELineParser` that yields empty lines verbatim.
//
//   2. `DishCard.RecipePlanWire.IngredientWire` required `amount_text`
//      and `is_optional` non-optional, but the backend / Gemini
//      occasionally omits either key. Fix: custom `init(from:)` that
//      defaults `amountText` to "" and `isOptional` to `nil`.
//
// Both bugs surfaced on-device as the generic "The data couldn't be
// read because it isn't in the correct format" message. These tests
// pin the fix so a future refactor can't silently regress.

import XCTest
@testable import Stir

final class AIDispatchDecoderTests: XCTestCase {

    // MARK: - SSELineParser

    func test_sseParser_yieldsEmptyLinesBetweenEvents() throws {
        // The failure mode: if the parser swallows empty lines, two
        // events look like one concatenated payload. This test fails
        // if anyone reverts to `bytes.lines`.
        var lines: [String] = []
        var parser = SSELineParser { line in
            lines.append(line)
        }
        let input = "event: dish\ndata: {\"a\":1}\n\nevent: dish\ndata: {\"b\":2}\n\n"
        for byte in input.utf8 {
            try parser.append(byte)
        }
        try parser.finalizePartialLine()

        XCTAssertEqual(lines, [
            "event: dish",
            "data: {\"a\":1}",
            "",  // ← the blank separator — must be present
            "event: dish",
            "data: {\"b\":2}",
            "",  // ← trailing blank before stream end
        ])
    }

    func test_sseParser_toleratesCRLF() throws {
        var lines: [String] = []
        var parser = SSELineParser { line in lines.append(line) }
        let input = "event: a\r\ndata: 1\r\n\r\n"
        for byte in input.utf8 {
            try parser.append(byte)
        }
        try parser.finalizePartialLine()
        XCTAssertEqual(lines, ["event: a", "data: 1", ""])
    }

    func test_sseParser_flushesTrailingPartialLine() throws {
        // Some streams terminate without a final newline. The parser
        // must still emit the last chunk.
        var lines: [String] = []
        var parser = SSELineParser { line in lines.append(line) }
        let input = "event: done\ndata: {\"ok\":true}"  // no trailing \n
        for byte in input.utf8 {
            try parser.append(byte)
        }
        try parser.finalizePartialLine()
        XCTAssertEqual(lines, ["event: done", "data: {\"ok\":true}"])
    }

    func test_sseParser_emptyInputEmitsNothing() throws {
        var lines: [String] = []
        var parser = SSELineParser { line in lines.append(line) }
        try parser.finalizePartialLine()
        XCTAssertEqual(lines, [])
    }

    // MARK: - DishCard decode — missing ingredient keys

    func test_dishCard_decodesWhenAmountTextOmitted() throws {
        let json = """
        {
          "rank": 1,
          "title": "T",
          "total_time_minutes": 10,
          "why_it_fits": "w",
          "missing_ingredient_count": 0,
          "fit_label_primary": "x",
          "hard_constraint_pass": true,
          "recipe_plan": {
            "servings": 2,
            "difficulty": 1,
            "ingredients": [
              { "display_name": "salt", "is_optional": false }
            ],
            "steps": []
          },
          "reasoning_summary": ""
        }
        """.data(using: .utf8)!

        // Previously this threw `keyNotFound(amount_text, …)` and
        // blocked the entire SSE stream from decoding.
        let card = try JSONDecoder.stir.decode(DishCard.self, from: json)
        XCTAssertEqual(card.recipePlan.ingredients.count, 1)
        XCTAssertEqual(card.recipePlan.ingredients[0].displayName, "salt")
        XCTAssertEqual(card.recipePlan.ingredients[0].amountText, "")
        XCTAssertEqual(card.recipePlan.ingredients[0].isOptional, false)
    }

    func test_dishCard_decodesWhenIsOptionalOmitted() throws {
        let json = """
        {
          "rank": 1,
          "title": "T",
          "total_time_minutes": 10,
          "why_it_fits": "w",
          "missing_ingredient_count": 0,
          "fit_label_primary": "x",
          "hard_constraint_pass": true,
          "recipe_plan": {
            "servings": 2,
            "difficulty": 1,
            "ingredients": [
              { "display_name": "salt", "amount_text": "to taste" }
            ],
            "steps": []
          },
          "reasoning_summary": ""
        }
        """.data(using: .utf8)!

        let card = try JSONDecoder.stir.decode(DishCard.self, from: json)
        XCTAssertEqual(card.recipePlan.ingredients[0].amountText, "to taste")
        // Nil (not `false`) when omitted — preserves "no signal" so
        // ambiguous ingredients don't silently flip to required.
        XCTAssertNil(card.recipePlan.ingredients[0].isOptional)
    }

    func test_dishCard_decodesFullPayload() throws {
        // Baseline: complete payload still round-trips. Guards against
        // the custom `init(from:)` accidentally dropping fields.
        let json = """
        {
          "rank": 2,
          "title": "Full",
          "total_time_minutes": 20,
          "why_it_fits": "w",
          "missing_ingredient_count": 1,
          "fit_label_primary": "fastest",
          "fit_label_secondary": "uses_what_you_have",
          "hard_constraint_pass": true,
          "recipe_plan": {
            "servings": 4,
            "difficulty": 2,
            "cuisine": "Italian",
            "ingredients": [
              {
                "display_name": "olive oil",
                "canonical_slug": "olive-oil",
                "amount_text": "2 tbsp",
                "is_optional": true
              }
            ],
            "steps": [
              { "step_number": 1, "instruction_text": "Heat oil.", "timer_seconds": 60 }
            ]
          },
          "reasoning_summary": "solid"
        }
        """.data(using: .utf8)!

        let card = try JSONDecoder.stir.decode(DishCard.self, from: json)
        XCTAssertEqual(card.rank, 2)
        XCTAssertEqual(card.fitLabelSecondary, "uses_what_you_have")
        XCTAssertEqual(card.recipePlan.cuisine, "Italian")
        let ing = card.recipePlan.ingredients[0]
        XCTAssertEqual(ing.displayName, "olive oil")
        XCTAssertEqual(ing.canonicalSlug, "olive-oil")
        XCTAssertEqual(ing.amountText, "2 tbsp")
        XCTAssertEqual(ing.isOptional, true)
    }

    // MARK: - decodeSSEEvent

    func test_decodeSSEEvent_dish_decodesWithOmittedOptionalKeys() throws {
        // End-to-end check that the SSE event decoder accepts a dish
        // payload whose ingredients omit both `amount_text` AND
        // `is_optional`. This is the exact shape that broke the
        // on-device flow.
        let dataJSON = """
        {"rank":1,"title":"T","total_time_minutes":10,"why_it_fits":"w",
         "missing_ingredient_count":0,"fit_label_primary":"x",
         "hard_constraint_pass":true,
         "recipe_plan":{"servings":2,"difficulty":1,
           "ingredients":[{"display_name":"salt"}],"steps":[]},
         "reasoning_summary":""}
        """
        let event = try XCTUnwrap(try decodeSSEEvent(event: "dish", dataJSON: dataJSON))
        guard case let .dish(card) = event else {
            XCTFail("expected .dish, got \(event)"); return
        }
        XCTAssertEqual(card.recipePlan.ingredients.count, 1)
        XCTAssertEqual(card.recipePlan.ingredients[0].amountText, "")
        XCTAssertNil(card.recipePlan.ingredients[0].isOptional)
    }

    func test_decodeSSEEvent_unknownEventReturnsNil() throws {
        // Defensive — unknown event types log a warning and return nil;
        // the dispatcher skips them.
        let result = try decodeSSEEvent(event: "mystery", dataJSON: "{}")
        XCTAssertNil(result)
    }
}
