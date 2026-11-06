// compute_cost_usd_test
//
// Unit tests for `computeCostUSD` in _shared/ai_request_log.ts. Exercises
// the pure-function cost arithmetic without any HTTP or DB dependencies.
//
// Covers:
//   - Realtime voice turn (gpt-realtime-2.1-mini) uncached and cached
//   - cachedInputTokens discounts the cached portion at the vendor's
//     published cached rate (Gemini Flash 10%) and leaves non-text inputs untouched
//   - cacheWriteInputTokens bills the Claude cache-write rate on its share
//   - Defensive clamp: `cachedInputTokens > textInputTokens` doesn't
//     produce a negative uncached-text portion
//   - Flash generateContent path: cached portion is genuinely cheaper

import { assertEquals } from '@std/assert';
import { computeCostUSD } from '../functions/_shared/ai_request_log.ts';
import { GeminiModel } from '../functions/_shared/gemini.ts';
import { ClaudeModel } from '../functions/_shared/claude.ts';
import { OpenAIRealtimeModel } from '../functions/_shared/realtime_mint.ts';

Deno.test('computeCostUSD discounts cached text portion at 10% rate (Flash)', () => {
  // Flash textInPer1M = $0.50, cachedInPer1M = $0.05 (verified 2026-11-06).
  // 2000 text in total, 1000 of which are cached:
  //   uncached: 1000 * $0.50  / 1e6 = $0.000500
  //   cached:   1000 * $0.05  / 1e6 = $0.000050
  //   out:       500 * $3.00  / 1e6 = $0.001500
  //   total                         = $0.002050
  const cost = computeCostUSD(GeminiModel.Flash, {
    textInputTokens: 2000,
    cachedInputTokens: 1000,
    textOutputTokens: 500,
  });
  assertEquals(cost, 0.00205);
});

Deno.test('computeCostUSD with all text cached costs 10% of the fully-uncached case', () => {
  // Full cache hit on a pure-text Flash call — cost should collapse to
  // exactly 10% of the uncached cost (input tier only; output is identical).
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
  //   allCached:  10000 * $0.05  / 1e6 = $0.000500
  //   ratio = 0.10
  assertEquals(full, 0.005);
  assertEquals(allCached, 0.0005);
  assertEquals(Math.round((allCached / full) * 100) / 100, 0.1);
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
  //   total = 8000 * $0.05 / 1e6 = $0.000400
  assertEquals(cost, 0.0004);
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

Deno.test('computeCostUSD splits Claude input into uncached, cache-read and cache-write (Haiku 5.5)', () => {
  // Haiku 5.5: input $0.10, cache read $0.01, cache write $0.125, output $0.50.
  // 10000 input total = 6000 uncached + 3000 cache read + 1000 cache write:
  //   uncached:   6000 * $0.10  / 1e6 = $0.000600
  //   read:       3000 * $0.01  / 1e6 = $0.000030
  //   write:      1000 * $0.125 / 1e6 = $0.000125
  //   out:        2000 * $0.50  / 1e6 = $0.001000
  //   total                           = $0.001755
  const cost = computeCostUSD(ClaudeModel.Haiku, {
    textInputTokens: 10_000,
    cachedInputTokens: 3000,
    cacheWriteInputTokens: 1000,
    textOutputTokens: 2000,
  });
  assertEquals(cost, 0.001755);
});

Deno.test('computeCostUSD realtime mini uncached voice turn', () => {
  // gpt-realtime-2.1-mini: text in $0.60, audio in $10, text out $2.40, audio out $20.
  //   text in:   3300 * $0.60  / 1e6 = $0.001980
  //   audio in:    38 * $10.00 / 1e6 = $0.000380
  //   text out:    16 * $2.40  / 1e6 = $0.0000384
  //   audio out:  100 * $20.00 / 1e6 = $0.002000
  //   total                          = $0.0043984 → 0.004398
  const counts = {
    textInputTokens: 3300,
    audioInputTokens: 38,
    textOutputTokens: 16,
    audioOutputTokens: 100,
  };
  assertEquals(computeCostUSD(OpenAIRealtimeModel.Mini, counts), 0.004398);
  // Zero cached counts are identical to omitting them.
  assertEquals(
    computeCostUSD(OpenAIRealtimeModel.Mini, { ...counts, cachedInputTokens: 0, cachedAudioInputTokens: 0 }),
    0.004398,
  );
});

Deno.test('computeCostUSD realtime mini prices cached text and cached audio at their own rates', () => {
  // Cached text $0.06, cached audio $0.30.
  //   text uncached:   300 * $0.60  / 1e6 = $0.000180
  //   text cached:    3000 * $0.06  / 1e6 = $0.000180
  //   audio uncached:  140 * $10.00 / 1e6 = $0.001400
  //   audio cached:    860 * $0.30  / 1e6 = $0.000258
  //   text out:         16 * $2.40  / 1e6 = $0.0000384
  //   audio out:       100 * $20.00 / 1e6 = $0.002000
  //   total                               = $0.0040564 → 0.004056
  const cost = computeCostUSD(OpenAIRealtimeModel.Mini, {
    textInputTokens: 3300,
    cachedInputTokens: 3000,
    audioInputTokens: 1000,
    cachedAudioInputTokens: 860,
    textOutputTokens: 16,
    audioOutputTokens: 100,
  });
  assertEquals(cost, 0.004056);
});

Deno.test('computeCostUSD clamps cachedAudioInputTokens ≤ audioInputTokens', () => {
  // Bogus cached audio above the audio total: all 500 audio tokens are
  // treated as cached, never a negative uncached portion.
  //   500 * $0.30 / 1e6 = $0.000150
  const cost = computeCostUSD(OpenAIRealtimeModel.Mini, {
    textInputTokens: 0,
    audioInputTokens: 500,
    cachedAudioInputTokens: 9999,
    textOutputTokens: 0,
  });
  assertEquals(cost, 0.00015);
});

Deno.test('providerForModel maps logged model IDs to the PostHog $ai_provider value', async () => {
  const { providerForModel } = await import('../functions/_shared/ai_observability.ts');
  assertEquals(providerForModel('claude-haiku-5-5'), 'anthropic');
  assertEquals(providerForModel('gpt-realtime-2.1-mini'), 'openai');
  assertEquals(providerForModel('gemini-3-flash-preview'), 'gemini');
  assertEquals(providerForModel('something-else'), 'unknown');
});
