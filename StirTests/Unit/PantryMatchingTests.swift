// PantryMatchingTests
//
// SCA-26 — pins the contract on `String.pantryMatchTokens()`. The
// matcher is the safety net for the auto-consume on cook completion
// (ADR 0029): when both the slug-match and the exact-name-match miss,
// this is what catches "Red Onion" vs "red onions". False-positive
// matches would auto-delete the wrong pantry row, so the test suite
// pins both the matches AND the non-matches we care about.

import XCTest
@testable import Stir

final class PantryMatchingTests: XCTestCase {
    // MARK: - Matches that must succeed

    func test_emptyString_returnsEmpty() {
        XCTAssertEqual("".pantryMatchTokens(), [])
        XCTAssertEqual("   ".pantryMatchTokens(), [])
    }

    func test_caseInsensitive() {
        XCTAssertEqual("Red Onion".pantryMatchTokens(), "red onion".pantryMatchTokens())
        XCTAssertEqual("RED ONION".pantryMatchTokens(), "red onion".pantryMatchTokens())
    }

    func test_pluralS_matches_singular() {
        XCTAssertEqual("onion".pantryMatchTokens(), "onions".pantryMatchTokens())
        XCTAssertEqual("scallion".pantryMatchTokens(), "scallions".pantryMatchTokens())
    }

    func test_pluralES_matches_singular() {
        // tomato/tomatoes — Tier-2 'es' branch.
        XCTAssertEqual("tomato".pantryMatchTokens(), "tomatoes".pantryMatchTokens())
    }

    func test_pluralIES_matches_singular_y() {
        // berry/berries — Tier-1 'ies' branch.
        XCTAssertEqual("berry".pantryMatchTokens(), "berries".pantryMatchTokens())
    }

    func test_hyphenAndPunctuation_normalize() {
        XCTAssertEqual("Red-Onion".pantryMatchTokens(), "red onion".pantryMatchTokens())
        XCTAssertEqual("Red, Onion!".pantryMatchTokens(), "red onion".pantryMatchTokens())
    }

    func test_wordOrder_isSorted() {
        // ["red", "onion"] not ["onion", "red"] — sorted alphabetically.
        XCTAssertEqual("Red Onion".pantryMatchTokens(), ["onion", "red"])
        XCTAssertEqual("Onion, Red".pantryMatchTokens(), ["onion", "red"])
        // Same set regardless of input order:
        XCTAssertEqual("Red Onion".pantryMatchTokens(), "Onion Red".pantryMatchTokens())
    }

    func test_extraWhitespace_collapsed() {
        XCTAssertEqual("  red    onion  ".pantryMatchTokens(), "red onion".pantryMatchTokens())
    }

    // MARK: - Non-matches that MUST stay separate (false-positive defense)

    func test_oliveOil_does_not_match_oliveOilSpray() {
        // The motivating false-positive case from ADR 0029. Different
        // token counts → set inequality → no match.
        XCTAssertNotEqual("olive oil".pantryMatchTokens(), "olive oil spray".pantryMatchTokens())
    }

    func test_yellowOnion_does_not_match_redOnion() {
        // Color modifiers are real differentiators; auto-consuming a
        // red onion when the recipe wanted yellow is a real bug.
        XCTAssertNotEqual("yellow onion".pantryMatchTokens(), "red onion".pantryMatchTokens())
    }

    func test_tomato_does_not_match_tomatoSauce() {
        XCTAssertNotEqual("tomato".pantryMatchTokens(), "tomato sauce".pantryMatchTokens())
    }

    func test_freshBasil_does_not_match_driedBasil() {
        XCTAssertNotEqual("fresh basil".pantryMatchTokens(), "dried basil".pantryMatchTokens())
    }

    // MARK: - Lemmatization corner cases (don't strip short tokens)

    func test_shortTokensNotStripped() {
        // "is", "as", "yes" must stay intact — only tokens >3 chars
        // get the plural strip. Otherwise "is" would normalize to "i".
        XCTAssertEqual("is".pantryMatchTokens(), ["is"])
        XCTAssertEqual("as".pantryMatchTokens(), ["as"])
        XCTAssertEqual("yes".pantryMatchTokens(), ["yes"])
    }

    func test_oss_endingShortToken_unchanged() {
        // "boss" is exactly 4 chars — fits the >3 guard. Becomes "bos".
        // Acceptable: "boss" isn't a pantry ingredient. The corner-
        // case behavior is documented; we don't try to be clever.
        XCTAssertEqual("boss".pantryMatchTokens(), ["bos"])
    }

    // MARK: - Numeric content survives

    func test_numbersStaySeparate() {
        // Unusual ingredient names with digits ("00 flour") — keep the
        // digits as their own token so they participate in matching.
        XCTAssertEqual("00 flour".pantryMatchTokens(), ["00", "flour"])
    }

    // MARK: - Real-world scenarios from ADR 0029 trigger

    func test_scenario_dinnerSolveOutput_matchesPantryParseInput() {
        // The motivating production scenario. Pantry-parse stores
        // "Red onion" verbatim; dinner-solve emits "Red onions" or
        // "Red Onion, diced" in recipe ingredients. Without Tier-3
        // normalization, consume misses both. With it, both match.
        XCTAssertEqual("Red onion".pantryMatchTokens(), "red onions".pantryMatchTokens())
        // "Red onion, diced" adds an extra modifier and SHOULD NOT
        // match the bare "Red onion" — different ingredient prep.
        // (Caught by sorted-set inequality, even with normalization.)
        XCTAssertNotEqual("Red onion".pantryMatchTokens(), "Red onion, diced".pantryMatchTokens())
    }
}
