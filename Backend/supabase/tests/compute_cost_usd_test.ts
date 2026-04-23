// compute_cost_usd_test
//
// Unit tests for `computeCostUSD` in _shared/ai_request_log.ts. Exercises
// the pure-function cost arithmetic without any HTTP or DB dependencies.
//
// Covers:
//   - Baseline case (voice turn, no caching) matches the spike-validated
//     $0.006/turn figure from CLAUDE.md §Cost model
//   - cachedInputTokens discounts the cached portion at 25% of textInPer1M
//     and leaves non-text inputs untouched
//   - Defensive clamp: `cachedInputTokens > textInputTokens` doesn't
//     produce a negative uncached-text portion
//   - FlashLivePreview with cached=0 (the ADR 0015 locked-in steady state)
//     produces exactly the old pre-discount cost — no regression
//   - Flash generateContent path: cached portion is genuinely cheaper

import { assertEquals } from '@std/assert';
import { computeCostUSD } from '../functions/_shared/ai_request_log.ts';
import { GeminiModel } from '../functions/_shared/gemini.ts';

Deno.test('computeCostUSD baseline voice turn matches $0.006', () => {
  // CLAUDE.md §Cost model baseline: 1000 text sys prompt + 1150 audio in +
  // 150 audio out on FlashLivePreview.
  const cost = computeCostUSD(GeminiModel.FlashLivePreview, {
    textInputTokens: 1000,
    audioInputTokens: 1150,
    textOutputTokens: 0,
    audioOutputTokens: 150,
  });
  //   text in:   1000 * $0.75  / 1e6 = $0.000750
  //   audio in:  1150 * $3.00  / 1e6 = $0.003450
  //   audio out: 150  * $12.00 / 1e6 = $0.001800
  //   total                          = $0.006000
  assertEquals(cost, 0.006);
});

Deno.test('computeCostUSD with cachedInputTokens=0 is identical to omitting the param', () => {
  const counts = {
    textInputTokens: 1000,
    audioInputTokens: 1150,
    textOutputTokens: 0,
    audioOutputTokens: 150,
  };
  const without = computeCostUSD(GeminiModel.FlashLivePreview, counts);
  const withZero = computeCostUSD(GeminiModel.FlashLivePreview, {
    ...counts,
    cachedInputTokens: 0,
  });
  assertEquals(without, withZero);
  assertEquals(without, 0.006);
});

Deno.test('computeCostUSD discounts cached text portion at 25% rate (Flash)', () => {
  // Flash textInPer1M = $0.50, cachedInPer1M = $0.125.
  // 2000 text in total, 1000 of which are cached:
  //   uncached: 1000 * $0.50  / 1e6 = $0.000500
  //   cached:   1000 * $0.125 / 1e6 = $0.000125
  //   out:       500 * $3.00  / 1e6 = $0.001500
  //   total                         = $0.002125
  const cost = computeCostUSD(GeminiModel.Flash, {
    textInputTokens: 2000,
    cachedInputTokens: 1000,
    textOutputTokens: 500,
  });
  assertEquals(cost, 0.002125);
});

Deno.test('computeCostUSD with all text cached costs 25% of the fully-uncached case', () => {
  // Full cache hit on a pure-text Flash call — cost should collapse to
  // exactly 25% of the uncached cost (input tier only; output is identical).
  const full = computeCostUSD(GeminiModel.Flash, {
    textInputTokens: 10_000,
    textOutputTokens: 0,
  });
  const allCached = computeCostUSD(GeminiModel.Flash, {
    textInputTokens: 10_000,
    cachedInputTokens: 10_000,
    textOutputTokens: 0,
  });
  //   full:       10000 * $0.50  / 1e6 = $0.005000
  //   allCached:  10000 * $0.125 / 1e6 = $0.001250
  //   ratio = 0.25
  assertEquals(full, 0.005);
  assertEquals(allCached, 0.00125);
  assertEquals(Math.round((allCached / full) * 100) / 100, 0.25);
});

Deno.test('computeCostUSD clamps cachedInputTokens ≤ textInputTokens', () => {
  // A malformed caller passes cached > text — the function must clamp
  // to prevent negative uncached and still produce a sane cost. The
  // Zod wire validator rejects this shape upstream; this is defense
  // in depth for direct programmatic callers.
  //
  // Input scaled large enough that the 6-decimal round at the end
  // doesn't collapse the expected value (Math.round(62.5)=63 would
  // otherwise make the expectation 0.0000625 → 0.000063 after round
  // and obscure whether the clamp is working vs the rounding).
  const cost = computeCostUSD(GeminiModel.Flash, {
    textInputTokens: 8000,
    cachedInputTokens: 999_999, // bogus
    textOutputTokens: 0,
  });
  //   clamped cached = 8000, uncached = 0
  //   total = 8000 * $0.125 / 1e6 = $0.001000
  assertEquals(cost, 0.001);
});

Deno.test('computeCostUSD FlashLivePreview with cached=0 matches pre-discount math (ADR 0015 steady state)', () => {
  // Regression guard: ADR 0015 locks in "cached never fires on Live,"
  // so every real Live call passes cached=0 and the cost must remain
  // exactly what the CLAUDE.md cost model asserts. If someone ever
  // changes FlashLivePreview.cachedInPer1M to something like 0 (instead
  // of 25%), this test stays green because cached=0 is a no-op — the
  // complementary test above guards the non-zero path.
  const liveCost = computeCostUSD(GeminiModel.FlashLivePreview, {
    textInputTokens: 4000,
    cachedInputTokens: 0,
    audioInputTokens: 500,
    textOutputTokens: 0,
    audioOutputTokens: 125,
  });
  //   text:      4000 * $0.75  / 1e6 = $0.003000
  //   audio in:   500 * $3.00  / 1e6 = $0.001500
  //   audio out:  125 * $12.00 / 1e6 = $0.001500
  //   total                          = $0.006000
  assertEquals(liveCost, 0.006);
});

Deno.test('computeCostUSD lower-bounds negative cachedInputTokens at 0', () => {
  // Review finding: if a buggy caller passes a negative cached count,
  // the pre-fix version produced `uncached = text - (-N) = text + N`,
  // inflating the uncached portion and over-reporting cost. The two-
  // sided clamp must floor cached at 0 so the uncached portion equals
  // `textInputTokens` exactly.
  const cost = computeCostUSD(GeminiModel.Flash, {
    textInputTokens: 10_000,
    cachedInputTokens: -500, // bogus / programmatic bug
    textOutputTokens: 0,
  });
  //   clamped cached = 0, uncached = 10_000
  //   total = 10_000 * $0.50 / 1e6 = $0.005000
  assertEquals(cost, 0.005);
});

Deno.test('computeCostUSD coerces NaN/Infinity inputs to 0 (defense in depth)', () => {
  // Non-finite counts can arrive from malformed JSON.parse upstream
  // or a caller-side arithmetic bug. The pre-fix version propagated
  // NaN into cost_usd, which either failed the NUMERIC(10,6) DB
  // constraint at insert or serialized as null. Function-level
  // coercion to 0 makes a caller bug visible as "suspiciously
  // zero-cost row" rather than a silent insert failure.
  const allNaN = computeCostUSD(GeminiModel.Flash, {
    textInputTokens: NaN,
    cachedInputTokens: NaN,
    textOutputTokens: NaN,
  });
  assertEquals(allNaN, 0);

  const infinity = computeCostUSD(GeminiModel.Flash, {
    textInputTokens: Infinity,
    textOutputTokens: 500,
  });
  // Text input coerced to 0; output still charged normally.
  //   out: 500 * $3.00 / 1e6 = $0.001500
  assertEquals(infinity, 0.0015);
});

Deno.test('computeCostUSD handles zero textInputTokens gracefully', () => {
  // Degenerate input: zero text input with a non-zero cached count
  // shouldn't produce phantom cost. The double-clamp ensures cached
  // collapses to 0 when textInputTokens is 0.
  const cost = computeCostUSD(GeminiModel.Flash, {
    textInputTokens: 0,
    cachedInputTokens: 1000, // meaningless without text input
    audioInputTokens: 0,
    textOutputTokens: 0,
  });
  assertEquals(cost, 0);
});

Deno.test('computeCostUSD discounts cached text on Live when non-zero (hypothetical future)', () => {
  // Defensive behavior: IF Live caching ever starts firing, the cost
  // math reflects the 25% discount. FlashLivePreview.cachedInPer1M =
  // $0.1875 (25% of $0.75).
  const cost = computeCostUSD(GeminiModel.FlashLivePreview, {
    textInputTokens: 4000,
    cachedInputTokens: 2000,
    audioInputTokens: 500,
    textOutputTokens: 0,
    audioOutputTokens: 125,
  });
  //   uncached text: 2000 * $0.75   / 1e6 = $0.001500
  //   cached text:   2000 * $0.1875 / 1e6 = $0.000375
  //   audio in:       500 * $3.00   / 1e6 = $0.001500
  //   audio out:      125 * $12.00  / 1e6 = $0.001500
  //   total                               = $0.004875
  assertEquals(cost, 0.004875);
});
