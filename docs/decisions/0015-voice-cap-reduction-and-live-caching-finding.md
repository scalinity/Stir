# ADR 0015: Voice cap reduction (Premium 20→13, Pro 40→27) and permanent "no caching on Live API" assumption

- **Status**: Accepted
- **Date**: 2026-04-23
- **Owner-step**: Step 6 wrap-up; caps apply from this release forward
- **Related**: CLAUDE.md §Tier entitlements · CLAUDE.md §Cost model · CLAUDE.md §Gemini Live sharp-edges · Spec §9 "Cost model" · Spec §5 "Tier entitlements" · ADR 0008 (voice-temporarily-free during testing — supersedes-adjacent for Free-tier cap) · ADR 0010 (max_output_tokens 400) · ADR 0014 (session refresh IS pruning) · `_shared/entitlements.ts` · `voice-turn-usage/index.ts` · `ai_observability.ts`

## Context

Step 6 device-testing (2026-04-22 → 2026-04-23) produced three load-bearing measurements that invalidate the pre-step-6 cap assumptions:

1. **Implicit context caching does NOT fire on BidiGenerateContent / Gemini Live workloads.** The default-on implicit caching that Gemini 2.5/3 Flash gives `generateContent` callers never materializes on the Live API. Across 50+ voice turns spanning three device sessions, `usageMetadata.cachedContentTokenCount` was either absent from the frame or present-and-zero. This is consistent with, and empirically confirms, the `cache — not supported` entry in Google's published pricing table for `gemini-3.1-flash-live-preview`. Code-level observability for this has been live since 2026-04-22 (new column `ai_request_log.prompt_cached_tokens`, PostHog `$ai_cache_read_input_tokens` property, partial index for the trigger-query path in migration `20260422000009`).
2. **Per-turn voice cost runs ~$0.006 steady-state** (125 new audio in + 825 carried audio in + ~200 AUDIO-mode overhead + 1000 text sys prompt in + 150 audio out), yielding ~$0.090 per 15-turn cooking session. This number has no caching discount baked in and is stable across device runs.
3. **Session refresh cadence 4 / token budget 10k** (ADR 0014) caps per-turn prompt growth at the carried-audio tail; growing that tail is not a viable cost-reduction lever without regressing UX.

The pre-step-6 cap grid (Premium 20 voice sessions / mo, Pro 40 voice sessions / mo) was built while holding the door open for "implicit caching may reduce carried-audio cost by 20-40% once live." With measurement #1 now locked, that door is closed. Holding the old caps would push Premium AI spend from $1.89/mo to ~$2.08/mo (24.5% of $8.49 net ARPU, over the 22.27% guardrail) and Pro AI spend from $3.69/mo to ~$3.95/mo (eroding what little year-1 Pro-annual margin remains). The cost model in CLAUDE.md §Cost model already reflects a no-cache world; the caps were the lagging indicator.

We also accumulated one new category of operational risk: Gemini Live is preview-labeled and has stateful protocol bugs (see sharp-edge #20 in CLAUDE.md — missing `turnComplete` after multi-pass tool-call turns, 2026-04-23 device observation). The client-side watchdog lands in the same release as this cap change; its fire rate is a second-order cost-model input and a trigger-to-revisit signal below.

## Decision

1. **Voice cap cut.**
   - Premium: 20 → **13** voice cook sessions / month.
   - Pro: 40 → **27** voice cook sessions / month.
   - Free: stays 0 (reverting the ADR 0008 testing bump as part of this release).
2. **Lock "implicit caching does not fire on Live API" as a permanent assumption in the Stir cost model, indefinitely, until empirically proven otherwise.** No cost-model scenario, paywall economics spreadsheet, or margin analysis may assume non-zero caching savings on voice turns. Caching observability stays live so the assumption can be revisited if the signal changes (see trigger below), but the default posture is "zero."
3. **Raising caps above Premium 13 / Pro 27 is not a unilateral flip.** It requires: (a) the trigger-to-revisit criterion below has fired with measurement, AND (b) a revenue/cost re-measurement using post-trigger data, AND (c) an ADR revision that supersedes this one. "It seems fine" is not sufficient.

## Alternatives considered

- **Preserved-pricing price raise (Apple's grandfathering rule lets us increase subscription prices without auto-cancelling existing subscribers).** Rejected because the first nine months of paid users are the people whose trust we need most; hitting them with a price raise before product-market fit is validated would destroy retention and goodwill for a ~$1/mo margin swing we can achieve by cap trim. Revisit only if caps at 13/27 still don't close the margin gap after three months of actual usage data.
- **Switch voice to OpenAI Realtime (gpt-4o-realtime-preview).** Rejected by the single-vendor invariant (CLAUDE.md north-star #1). The invariant is accepting a ~20-40% theoretical cost ceiling on voice in exchange for operational simplicity, prompt-version portability, and a single Edge-Function code path. This measurement does not change that tradeoff. Revisit only if Gemini Live has sustained (quarterly) downtime or pricing drift that invalidates the base case.
- **Defer voice to post-v1.** Rejected because voice IS the Premium-tier differentiator. Premium without voice is ~$8.49 ARPU against a product that offers nothing meaningfully beyond Free tier — kills the paywall. Every other deferral option we explored pre-step-6 also rejected this for the same reason; not reopening here.
- **Ship at 20/40 and eat the margin.** Rejected. Pro annual year-1 margin is already $4.13/mo per CLAUDE.md §Billing; absorbing an additional $0.26/mo leaves $3.87 — inside the "one bad usage month ends the cohort's profitability" zone. Cap trim is the first-resort lever; margin erosion is a last resort.
- **Route voice through text-path fallback more aggressively to dodge the audio-token premium.** Rejected. Text-path fallback is the degraded UX (AI-VOICE-01 banner). Using it as a cost-shaping lever would misattribute user frustration to a vendor issue. Real users complain when voice is "sometimes slow" more than when it's rationed.

## Consequences

### Positive

- Premium AI spend lands at ~$1.29/mo (15.2% of $8.49 ARPU) — well under the 22.27% guardrail, with headroom for 30-day usage drift.
- Pro AI spend lands at ~$2.79/mo (post-fee margin comfortable at $139.99/yr).
- The cost model in CLAUDE.md now reflects only measured inputs. No "future optimistic caching" assumption that needs unwinding if the signal stays at zero.
- Voice observability (cached-token wire-up, stuck-watchdog PostHog, session-refresh callbacks) gives us a real dashboard for the assumption-revisit trigger below. If caching behavior does change, we'll see it in the trigger query the day it starts firing.

### Negative

- Premium users get ~13 voice sessions / month instead of ~20. Marketing and paywall copy must update in the same release (CLAUDE.md §Tier entitlements is the source of truth; RevenueCat / paywall copy / in-app gating all read from it).
- The ADR 0008 revert (Free 20 → 0) also lands in this release; any beta testers who had grown accustomed to free voice during step-6 development will need a Premium subscription to keep using it. This is the expected state, but flag in release notes.
- Competitive positioning: at 13 voice sessions/mo, a heavy user (daily cooker) will hit the cap on day ~14 of the month. This is a known funnel-edge; spec §16 "paywall" and step-7 reactivation messaging will need to address "you just hit your voice cap" as a distinct path from "you just tried a Premium-gated feature."
- 5% heavy-user tail: the top 5% of Premium voice-users historically run ~2.3x the median session count. At median = 6/mo × 2.3 = 14 sessions, they will hit the cap. The cost from a heavy user who hits cap = $0.09 × 13 = $1.17 capped spend (vs $1.80+ uncapped at 20 sessions). Cap performs its function — it bounds the tail. LTV arithmetic: a capped Premium heavy user is still profitable on month 1 ($1.29 AI / $8.49 ARPU) and renewal month 2+ is pure margin unless usage grows — the behavioral question is whether a hit-cap user churns. If the hit-cap → churn rate exceeds 10% in beta observation, the cap was too aggressive and we revisit. If below, the cap held.

### Tradeoffs

- Trading cap generosity for pricing integrity and unit-economic sustainability. A lower cap + preserved price is a durable choice; a higher cap + absorbed margin is a cliff waiting for the first power-user cluster. We've chosen durable.
- Trading "product looks unlimited-feeling" for "product has clear, understandable limits that the user can plan around." 13 sessions/mo is closer to the median weekday-cooking pattern (3 cooking-heavy days × 4 weeks ≈ 12 sessions) than 20 was — 20 was "generous" in a way that never mapped cleanly to any usage shape.

## Trigger to revisit

Raise caps back toward the old 20/40 grid if ALL of:

1. **Caching starts firing on Live API.** Concrete measurable: rolling 100-voice-session median of `ai_request_log.prompt_cached_tokens / input_tokens` ≥ 0.30 across at least 30 days of production traffic (partial index in migration `20260422000009` already supports this query). This measurement is authoritative — Google's published pricing page is advisory and has been known to change under us without notice.

   Trigger query:

   ```sql
   SELECT AVG(prompt_cached_tokens::numeric / NULLIF(input_tokens, 0))
   FROM ai_request_log
   WHERE feature_key = 'cook_mode_realtime'
     AND prompt_cached_tokens IS NOT NULL
     AND created_at > NOW() - INTERVAL '30 days'
   ORDER BY created_at DESC
   LIMIT 100;
   ```

   Returns `NULL` or `< 0.15` ⇒ assumption holds; no revisit.
   Returns `≥ 0.30` ⇒ cost model needs re-run and cap revisit is on the table.

2. **Beta voice-cap hit-rate is below ~30% of the Premium cohort per billing period** (measurable via `voice_cook_session` counter snapshots at period_end). Caps below the active-usage tail are functional; caps below the median are punitive and revisit-worthy for a different reason — under-serving paying users.

3. **Margin model re-run confirms the new cap still holds the 22.27% Premium / ≥ $3/mo Pro margin floor.** If the re-run fails the floor check even after caching is factored in, the fix is not "raise the cap" — it's a fresh ADR on pricing or tier restructure.

**Guard rail: raising caps before criterion #1 fires requires revenue/cost re-measurement and an ADR that supersedes this one, even if criteria #2 and #3 are satisfied.** Caching is the load-bearing assumption; the other criteria are contextual.

Secondary revisit trigger (unrelated to the caching finding but keyed to the same release): **if `voice_turn_stuck_watchdog_fired` exceeds 5% of tool-call turns in production over a rolling 7-day window, revisit CLAUDE.md §Voice validation plan #4 and spec §18 "Vendor contingency."** The watchdog landing in this release is the mitigating instrumentation; sustained fire rate above that threshold means the preview-API statefulness is a material risk, not a rare edge, and the single-vendor invariant needs re-examination. This does not reopen cap math — it opens the vendor-strategy conversation, which is a separate ADR if it fires.

## Notes

- Empirical caching measurement: 2026-04-22 device session, turns 1-15 of `session_id=b1a3…` — every `usageMetadata.cachedContentTokenCount` was 0 or absent. Logged via the `audio.chunk` / `usage.metadata` VoiceSessionLog channels; reconcilable against `ai_request_log.prompt_cached_tokens` (column added same day).
- Cost model inputs feeding the cap math come from CLAUDE.md §Cost model (post-step-6 measured-numbers update, 2026-04-22). This ADR does not re-derive them; it pins the caching assumption and cuts caps accordingly.
- Spec §5 entitlements grid and CLAUDE.md §Tier entitlements section must land in the same PR as the `_shared/entitlements.ts` cap change. Silent drift between those three is banned (CLAUDE.md self-rule §"if this file disagrees with the spec, the spec wins").
- Paywall copy update: the "3× ratio" framing ("Premium gets up to 20; Pro gets up to 40") becomes "up to 13 / up to 27." ADR does not block on the copy update, but it must ship same release — the first paying user who sees old copy + new cap is a refund request.
- Free tier revert (20 → 0) is ADR 0008's trigger firing ("before step 9 beta prep"); landing it here consolidates the cap reshuffle into one release. ADR 0008 moves from Accepted to Superseded-by-0015 on merge.
- Rejected Option B refactor (`tier_quotas` table as single source of truth vs `entitlements.ts` constants) is tracked separately as a step-8 ops item, not part of this ADR.
