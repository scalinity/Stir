# ADR 0013: iOS vs backend token accounting — two authorities, non-overlapping grains

- **Status**: Accepted
- **Date**: 2026-04-22
- **Owner-step**: Step 6 (voice) — unblocks dashboards independent of pruning/refresh resolution
- **Related**: ADR 0009 (PostHog LLM Observability), `_shared/ai_observability.ts`, `voice-turn-usage/index.ts`, `RealtimeSession.flushPendingReport`, D.1 validation gate

## Context

During D.1 pruning investigation on 2026-04-22, cross-referencing voice session cost in PostHog surfaced a persistent ~5-7% divergence between iOS-accumulated turn totals and backend-logged `$ai_generation` events. Both numbers are "correct" for their respective grain — but dashboards that compare or sum them produce misleading cost and budget metrics.

Two distinct accounting models exist, each driven by a different source of truth:

| Layer | What it counts | Source | Feature-level granularity |
| --- | --- | --- | --- |
| **iOS `accum_prompt_tokens`** (turn-level aggregate) | Sum of every `usageMetadata` frame received during a single Live turn, including post-tool-response re-prompts. The server re-sends full session context each time the turn resumes (CLAUDE.md sharp-edge #1), and every one of those frames emits its own `usageMetadata`. iOS accumulates them in `turnUsageAccumulator` and reports the sum to `/v1/ai/voice-turn-usage` as one row per turn. | Gemini Live WebSocket `usageMetadata` frames | Coarse — one number per turn, irrespective of whether a tool call happened mid-turn |
| **Backend `ai_request_log`** (AI-call-level ledger) | One row per individual LLM API call. `voice_cook_turn` rows mirror iOS's turn-level aggregate exactly (voice-turn-usage endpoint records what iOS sent). Other features — `substitution`, `cook_turn`, `dinner_solve`, etc. — log their own `generateContent` call tokens only, NOT whatever else was happening on the Live session around them. | Edge Function response metadata via `recordAIRequest` | Fine — one row per call, per feature |

The ~5-7% divergence arises when a dashboard reconciles these two grains without accounting for their different scopes.

### Concrete example of a divergence scenario

Imagine a voice session where turn 3 invokes `substitution_check`:

1. User speaks ("Can I swap butter?"). Live session processes user audio → emits `toolCall(substitution_check)`. `usageMetadata` frame reports `prompt_tokens=3501`.
2. iOS catches the tool call, dispatches to `/v1/ai/substitution`. Backend Edge Function calls Gemini Flash (separate API, separate session). The Flash call logs its OWN tokens to `ai_request_log` as feature_key=`substitution`, input=~600.
3. iOS sends `toolResponse` back to the Live session. Server re-prompts with full context + tool response → emits spoken reply. `usageMetadata` frame reports `prompt_tokens=3642`.
4. iOS turn ends. `accum_prompt_tokens` = 3501 + 3642 = 7,143. Dispatched to `/v1/ai/voice-turn-usage`. Backend records `feature_key='cook_mode_realtime'` row with input=7,143.
5. Two separate rows now exist in `ai_request_log` for the same user turn: 7,143 (voice_cook_turn) + 600 (substitution) = 7,743.

Two valid reads:
- **Billing view (canonical):** query `ai_request_log` grouped by `canonical_user_key` + time window → returns 7,743 for this turn. Both rows represent real Gemini API calls that cost real money. Sum is correct; no double-count.
- **UX view (turn-scoped):** iOS `voice_session_token_snapshot.cumulative_tokens` rolling sum includes only the voice-turn totals it accumulated (7,143). The substitution sub-call's 600 is NOT visible in iOS's view because the Live session's re-prompt already carried the tool response's context at full audio rate.

If a dashboard takes iOS's 7,143 (from `voice_session_token_snapshot`) and compares it to the backend's 7,743 (SUM across both rows for the turn's timespan), it perceives a 7.8% shortfall in iOS accounting. In reality nothing is missing — the two totals measure different things at different grains.

### Where the divergence MUST NOT be conflated

- **Quota enforcement & cost accrual:** `ai_request_log` is authoritative. Each row is a real billable API call. Summing rows gives true cost.
- **Runaway-cost alerting on voice sessions:** iOS `voice_session_token_snapshot.cumulative_tokens` is authoritative for "has this Live session crossed the soft cap?" It measures the Live session's prompt-token growth specifically (the thing the CLAUDE.md `tokenSoftCapPerSession=40k` threshold was designed to catch).
- **Per-feature cost-of-goods analysis:** `ai_request_log.feature_key` groupings give accurate per-feature unit costs. Splitting `cook_mode_realtime` from `substitution` is correct for Premium margin math.

### Where dashboards have been quietly broken

- **"Sum all AI cost for user X during voice session Y"** — if implemented as `iOS_reported_session_total + SUM(ai_request_log WHERE feature!='cook_mode_realtime')`, misses the overlap between Live re-prompts and tool-call context. The Live session DOES re-send the tool response's context as audio tokens on the post-tool re-prompt, which iOS captures; the standalone substitution row is a separate charge on top of (not inside of) that.
- **"$ai_generation cost per turn (from PostHog LLM Observability)"** — if a query plots both `voice_cook_turn` (iOS-aggregate) and `substitution` (feature-call) span_names on the same axis, it's comparing coarse to fine without disclaiming.

## Decision

**Rule 1 — Backend is canonical for billing.** `ai_request_log` rows are the single source of truth for cost, quota enforcement, Premium-margin analysis, and any "did we charge this correctly" question. RevenueCat webhooks, quota atomic RPCs, and Edge Function cost gates all key off `ai_request_log`. iOS's accumulator MUST NOT drive a billing decision.

**Rule 2 — iOS is canonical for Live-session turn aggregates.** `voice_session_token_snapshot.cumulative_tokens` and the iOS-emitted `$ai_input_state` / `$ai_output_state` on the close-time `$ai_trace` are the authorities for "how big has this specific Live session grown?" These drive runaway-cost alerting (the CLAUDE.md `tokenSoftCapPerSession=40_000` threshold), session-refresh decisions, and the "voice session cost hit cap" user-visible message. Backend `ai_request_log` MUST NOT drive these — feature-call rows don't aggregate the Live session's cross-turn bloat.

**Rule 3 — Dashboards MUST label grain explicitly.** Any chart that shows voice-session cost must disclose which source it's reading from. Charts that mix sources must either (a) filter to one feature_key (trivially non-overlapping), or (b) note in the chart subtitle: "Voice-turn totals include Live session re-prompts; tool-call features record standalone call cost. Sum across grains will approximate but not exactly equal session-level cost."

**Rule 4 — Don't reconcile numerically, reconcile structurally.** The 5-7% "divergence" is not a bug to fix. It's two systems measuring different quantities correctly. Trying to make them match by adjusting either source would introduce actual inaccuracy.

## Alternatives considered

- **Make iOS emit its own `$ai_generation` event per turn (independent of voice-turn-usage backend event)** — rejected. Would create three overlapping data sources instead of two, and violates ADR 0009's "dual-write reconciled by request id" contract. The voice-turn-usage backend event IS iOS's report; re-emitting from iOS directly would double-count.
- **Make the backend subtract tool-call sub-feature rows from the voice-turn row** — rejected. Technically plausible (subtract substitution `cost_usd` from the voice_cook_turn row that temporally contains it) but fragile: depends on timing correlation between a Live turn and a synchronous substitution call, and multi-tool turns would need per-tool attribution logic that doesn't exist. The simpler structural rule (different grains, don't mix) is robust without that complexity.
- **Drop the voice-turn-usage endpoint; log from backend directly by reading `$ai_generation` events posted by a client-side SDK** — rejected. Privacy posture (ADR 0009) forbids client-side PostHog LLM event emission because it bypasses the `ai_request_log` dual-write contract. The voice-turn-usage endpoint is specifically designed so backend can dual-write both the ledger row and the PostHog event atomically.

## Consequences

### Positive

- Dashboards can be updated immediately with the grain rules documented. Unblocks any "voice AI cost" chart work without waiting on the pruning/refresh resolution.
- Billing remains airtight — `ai_request_log` is the legal record of cost accrued.
- Runaway-cost alerting has a clear primary source (iOS `voice_session_token_snapshot`) rather than ambiguous "pick either."
- Any future investigator reading this sees WHY the numbers differ and doesn't chase a non-bug.

### Negative

- Dashboards are slightly more annotation-heavy. A chart can't simply SUM all `$ai_generation` events for a user and call it "voice session cost" — it has to filter by feature or disclose grain.
- Premium margin analysis must pick one grain per axis. If ops wants "total AI spend per Premium user per month," they use `ai_request_log`-backed queries (canonical billing). If they want "how many voice sessions hit the soft cap," they use the iOS-emitted token snapshots. The two don't plot on the same axis without careful labeling.

### Tradeoffs

- Complexity lives in the docs, not the code. Alternative paths would have simpler dashboards but would introduce genuine inaccuracy (either subtraction-based reconciliation that breaks on multi-tool turns, or client-side LLM emission that bypasses the dual-write contract). Choosing "document the grain split" over "paper it over numerically" is the right call for a system where billing correctness is load-bearing.

## Trigger to revisit

- PostHog LLM Observability changes its events model in a way that no longer supports feature-keyed queries (would force a dashboard-structural rework).
- The 5-7% divergence grows past 15% — suggests a new overlap mechanism has appeared (possibly from a future tool surface or prompt change) and the structural rule needs updated examples.
- iOS introduces a second Live-session-aware feature beyond Cook Mode, where the turn aggregate would need to accommodate non-voice turns. (Not imminent; v1 Live surface is Cook Mode only.)

## Notes

- This ADR is independent of ADR 0012 (step 6 v1 limitations) and ADR 0014 (session refresh as the actual pruning mechanism, landing alongside refresh implementation). It can be cited alone in dashboard documentation without dragging in the pruning conversation.
- The CLAUDE.md §Telemetry events table enumerates `voice_session_token_snapshot` and `$ai_trace` properties but doesn't currently describe the grain split. A follow-up edit should add a one-line note in the ADR 0009 context section pointing to this ADR for the "which source is canonical" question.
- Validation: the 30-turn refresh test session (task #58) is a good place to capture a concrete worked example of this grain split, with a substitution call mid-session, and pin the exact numerics to this ADR as an appendix once measured.
