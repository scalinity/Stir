// PaywallSubheadlineDriftTests
//
// SCA-314 S8: pin the inline cap numbers in `PaywallTrigger.subheadline`
// (Free 25 / Premium 250 / Pro 1000) against the canonical values that
// `Backend/supabase/functions/_shared/entitlements.ts::STANDING_PANTRY_CAPS`
// ships to iOS via `entitlements.standing_pantry_cap`.
//
// The risk this test guards: marketing copy in
// `PaywallTrigger.subheadline` is inline prose ("Premium remembers up
// to 250 ingredients. Pro remembers 1000."), and there is NO iOS-side
// constant that ties those numbers to a single source of truth — caps
// flow server → wire → `EntitlementService.serverStandingPantryCap`,
// so the iOS side has no tier→cap table to compare against. If the
// server bumps Pro from 1000 → 2000 in a future A/B (or shaves Free
// to 20), the subheadline strings here would silently lie until QA
// caught it.
//
// Strategy: assert that for each tier-bearing PaywallTrigger.subheadline,
// the canonical cap number for the relevant tier appears verbatim in
// the rendered string. Numbers are listed as the documented contract
// (`_shared/entitlements.ts` comment block, ~line 47: "truth for the
// values: free 25 / premium 250 / pro 1000"). If the server contract
// changes, update both files in the same commit.

import XCTest
@testable import Stir

final class PaywallSubheadlineDriftTests: XCTestCase {
    // Canonical caps mirrored from the Backend STANDING_PANTRY_CAPS
    // record. Treat this as a contract pin: changing one requires
    // changing both this constant AND the matching
    // `Backend/supabase/functions/_shared/entitlements.ts` row, in
    // the same commit.
    private let canonicalStandingPantryCaps: [Tier: Int] = [
        .free: 25,
        .premium: 250,
        .pro: 1000,
    ]

    /// The `.pantryCapReached` subhead is the only PaywallTrigger that
    /// inlines the standing-pantry-cap numbers in prose. Pin both the
    /// Premium (250) and Pro (1000) values against
    /// `canonicalStandingPantryCaps`.
    func test_pantryCapReachedSubheadline_includesPremiumAndProCanonicalCaps() {
        let subhead = PaywallTrigger.pantryCapReached.subheadline
        let premiumCap = canonicalStandingPantryCaps[.premium]!
        let proCap = canonicalStandingPantryCaps[.pro]!

        XCTAssertTrue(
            subhead.contains("\(premiumCap)"),
            "pantryCapReached subheadline must mention Premium cap \(premiumCap) verbatim; "
                + "found: \"\(subhead)\". Drift indicates server STANDING_PANTRY_CAPS.premium "
                + "changed without updating the marketing copy.",
        )
        XCTAssertTrue(
            subhead.contains("\(proCap)"),
            "pantryCapReached subheadline must mention Pro cap \(proCap) verbatim; "
                + "found: \"\(subhead)\". Drift indicates server STANDING_PANTRY_CAPS.pro "
                + "changed without updating the marketing copy.",
        )
    }

    /// Pro-anchored subheads (multiImageScanGate and the generic
    /// proValueProp paths) cite the Pro pantry cap as a secondary
    /// anchor ("1,000 pantry items"). Pin the Pro cap there too —
    /// same drift risk. Note: `voiceAffordanceTapped` is a
    /// voice-anchored trigger (its subhead leads with hands-free
    /// cooking + multi-image + favorites/widgets/leftovers) and
    /// intentionally omits the pantry count — exclude it.
    func test_proAnchoredSubheadlines_includeProPantryCap() {
        let proCap = canonicalStandingPantryCaps[.pro]!
        // Pro cap appears in the inline prose as "1,000" with a
        // thousands separator in the proValueProp string. Match both
        // shapes so a future copy edit that drops the separator
        // doesn't false-fail the test.
        let proCapShapes = ["\(proCap)", "1,000"]

        let proAnchoredTriggers: [PaywallTrigger] = [
            .voiceCookQuotaExhausted,
            .multiImageScanGate,
            .settingsUpgrade,
            .settingsProComparison,
            .dinnerSolveQuotaExhausted,
            .recipeImportQuotaExhausted,
            .savedFavoritesGate,
            .widgetsGate,
            .leftoversGate,
        ]

        for trigger in proAnchoredTriggers {
            let subhead = trigger.subheadline
            let matched = proCapShapes.contains(where: { subhead.contains($0) })
            XCTAssertTrue(
                matched,
                "PaywallTrigger.\(trigger).subheadline must mention Pro cap "
                    + "(\(proCapShapes.joined(separator: " or "))) verbatim; "
                    + "found: \"\(subhead)\". Drift indicates server "
                    + "STANDING_PANTRY_CAPS.pro changed without updating "
                    + "the marketing copy. Update entitlements.ts and "
                    + "PaywallTrigger.swift in the same commit.",
            )
        }
    }

    /// Belt-and-suspenders: assert that no subheadline accidentally
    /// inlines a number that ISN'T in the canonical caps table for
    /// the same tier (e.g. legacy 200, 500). This catches a partial
    /// copy edit that updates one trigger but not its siblings.
    ///
    /// We do NOT enforce "every subhead mentions all three caps" —
    /// most subheads anchor on Pro only because every trial CTA
    /// lands on Pro (SCA-294). Free's 25 only surfaces in
    /// ProComparisonSheet's static prose, not in any
    /// PaywallTrigger.subheadline.
    func test_noLegacyCapValuesInSubheadlines() {
        // Strings that USED to be in subhead prose but no longer are.
        // Each entry is matched as a word-boundary-aware regex so a
        // current value like "120 Dinner Solves" doesn't trigger a
        // false-positive on "20 Dinner Solves". `(?<!\d)` ensures the
        // leading number is not preceded by another digit; the rest
        // of the phrase is matched literally.
        let retiredCapPhrases = [
            "40 Dinner Solves",
            "20 Dinner Solves",
            "remembers up to 200",
            "remembers up to 500",
            "200 pantry items",
            "500 pantry items",
        ]
        for trigger in PaywallTrigger.allCases {
            let subhead = trigger.subheadline
            for retired in retiredCapPhrases {
                let pattern = "(?<!\\d)" + NSRegularExpression.escapedPattern(for: retired)
                let regex = try! NSRegularExpression(pattern: pattern)
                let range = NSRange(subhead.startIndex..., in: subhead)
                let match = regex.firstMatch(in: subhead, range: range)
                XCTAssertNil(
                    match,
                    "PaywallTrigger.\(trigger).subheadline inlines legacy "
                        + "phrase \"\(retired)\" — likely a partial cap "
                        + "migration. Full string: \"\(subhead)\".",
                )
            }
        }
    }
}
