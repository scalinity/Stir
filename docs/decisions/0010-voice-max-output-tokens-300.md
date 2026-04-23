# ADR 0010: Raise `max_output_tokens` on voice turns from 150 → 400

**Amendment 2026-04-22 (evening)**: bumped 300 → 400 after observing
that prompt v1.2.0 still allowed responses that stacked an apology +
step description + follow-up question, exceeding 300 tokens mid-
question. Turn 7 cut off at "How would..." on 2026-04-22. Prompt
v1.3.0 forbids apologies and follow-up questions; 400-token cap
gives headroom so any residual "model insisted on extras" case still
finishes cleanly rather than truncating mid-word. Cost delta from
300 → 400: +$0.0012/turn audio-output. Premium: +$0.36/mo per user.
Pro: +$0.72/mo per user.

---

- **Status**: Accepted
- **Date**: 2026-04-22
- **Owner-step**: Step 6 (voice)
- **Related**: CLAUDE.md §North-star constraint #8, CLAUDE.md §Cost model, `_shared/live_mint.ts`, ADR 0008 (voice temporarily free for testing)

## Context

CLAUDE.md #8 pinned `max_output_tokens: 150` as a "non-negotiable" cost-safety cap. 150 audio tokens is roughly 6 seconds of speech at 25 tokens/sec. That was set pre-testing based on a "1–2 short sentences" prompt assumption. In practice (observed turns 2026-04-22), the model frequently runs past 6 seconds on realistic cooking answers:

- "You're heating olive oil and garlic in the Dutch oven. Cook them until fragrant, which should take about [CUT]" — ran ~11 seconds before the cap cut it off mid-clause.
- "Step 5 is next. Heat olive oil and garlic over medium heat until fragrant, which should take about [CUT]" — same pattern.
- Doneness cues + amount conversions + safety addenda naturally push 2 sentences into the 8–12 second range.

Prompt v1.1.0 strengthened the brevity constraint ("2 short sentences max, under 6 seconds") and prompt v1.2.0 kept it. Even with the tighter prompt, responses consistently exceeded 150 tokens because real answers carry content density (amount + technique + cue) the model can't compress below a floor.

## Decision

Bump the default `max_output_tokens` for the Gemini Live mint from 150 → 300. 300 tokens covers ~12 seconds of audio — comfortably fits 2 sentences with content, retains a hard ceiling against runaway monologues.

## Alternatives considered

- **Stay at 150, tighten the prompt further** — already done in v1.1.0 and v1.2.0. Even with "Under 6 seconds. Nothing more." as a direct instruction, the model ran past the cap. Further tightening risks making responses uselessly terse ("Heat oil.") without fully eliminating the mid-sentence cutoff. Rejected.
- **Remove the cap entirely (use server default)** — Gemini's server default is generous (thousands of tokens). One long, unbounded monologue per turn could burn ~$0.05 on audio-out alone. Rejected — a bounded ceiling is the reason the constraint exists.
- **Make the cap a PostHog feature flag** — good for tuning but doesn't solve the baseline problem. A flag would still need a reasonable default. Deferred — can be layered on later if we want per-user tuning in D.1.
- **Bump to 200** — covers 8 seconds, which is closer to the prompt's "6 seconds" target but still cuts some realistic answers. Rejected — the extra 100 tokens at ~$0.0024/turn buys real headroom, not a marginal improvement.
- **Bump to 400 or higher** — overcorrects. Real answers longer than 10 seconds are a product problem (verbose model, not user-friendly in a kitchen). 300 is the tightest value that stops cutting observed answers without encouraging long-form output.

## Consequences

### Positive

- Responses finish cleanly instead of cutting off mid-sentence at the cap boundary. Removes a major user-visible polish gap observed across multiple sessions on 2026-04-22.
- Fixes a compounding problem: a cut-off response confuses the user, who then asks "what did you say?" — which is itself a turn charged at full price. Net cost impact is smaller than the raw per-turn delta.

### Negative

- **Per-turn audio-output cost rises from $0.0018 → $0.0036** (150 × $12/M → 300 × $12/M). Delta +$0.0018/turn.
- At 15 turns/session, session cost delta is +$0.027.
- Monthly cost impact per user:
  - Premium (20 sessions/mo cap): +$0.54/mo — 6.4% of the $8.49 net ARPU, acceptable.
  - Pro (40 sessions/mo cap): +$1.08/mo — raises Pro AI budget from $3.69 → ~$4.77 (24.4% of net Pro ARPU).

### Tradeoffs

- CLAUDE.md #8's "non-negotiable" framing was wrong. The spec treated 150 as a hard invariant when the real invariant is "bounded cap exists." 300 preserves that invariant at a per-turn cost the unit economics absorb. CLAUDE.md updated.
- Pro margin compresses but remains positive. If per-session turn count drifts upward in beta (>15 turns observed), revisit the cap or tighten the per-turn model more aggressively.

## Trigger to revisit

Re-evaluate the cap when ANY of the following:

1. Per-session observed turn count trends above 18 (would push Pro into margin-negative territory even at current AI budget).
2. Per-turn observed response length trends above 250 tokens average (cap isn't doing real work).
3. We switch to a different audio model whose pricing shifts the math (e.g., price drop → raise cap; price rise → tighten prompt further).
4. D.1 validation produces measured p95 response length data — tighten or loosen based on the real distribution rather than the model's nominal ceiling.

## Notes

- The prompt still tells the model "2 short sentences. Under 6 seconds. Nothing more." — this works with the cap as a ceiling, not as the target. Most responses should finish well under 300 tokens; the cap only protects against pathological long outputs.
- PostHog LLM observability events (`$ai_generation` with `$ai_output_tokens`) will measure the real distribution once wired. That telemetry is the feedback signal for trigger #4 above.
