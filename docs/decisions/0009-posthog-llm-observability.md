# ADR 0009: PostHog LLM Observability as the primary AI-cost dashboard

- **Status**: Accepted
- **Date**: 2026-04-22
- **Owner-step**: Step 6 (Cook Mode voice ships this alongside the Live path) · standing for all later AI features
- **Related**: Spec §15 (PostHog LLM Observability events) · CLAUDE.md §Telemetry events · `_shared/ai_observability.ts` · `voice-turn-usage/index.ts` · ai_request_log table · ADR 0004 (entitlement source of truth)

## Context

Every AI call in Stir already writes an `ai_request_log` row in Supabase — that table is the cost-attribution billing record and has the full retry-count / prompt-version / latency history. But nothing publishes those numbers to a live dashboard: Daniel has zero cost visibility in PostHog, the primary analytics tool, and no way to see per-feature cost-over-time without hand-querying Postgres. Gemini Live voice is even worse — turn-level usage only exists on the WebSocket as transient `usageMetadata` frames and isn't persisted anywhere.

PostHog ships an LLM Observability product ("LLM Analytics") that reads reserved `$ai_generation` and `$ai_trace` events and produces cost/latency/error dashboards natively. We need to wire Stir's AI calls into it while keeping `ai_request_log` as the authoritative billing record — no migration, no replacement.

## Decision

**Adopt PostHog LLM Observability as the primary live cost/latency dashboard via dual-write.** Every Edge Function that writes to `ai_request_log` also emits a `$ai_generation` event. Voice sessions emit exactly ONE `$ai_trace` at session close carrying BOTH `$ai_input_state` (mint context captured at VM attach time) and `$ai_output_state` (session totals) — PostHog is append-only, so a mint-time + close-time pair creates two sibling events rather than updating a single record. Cost is computed server-side from the authoritative `MODEL_PRICING` constants — iOS never computes costs. Reconciliation contract: `$ai_span_id = ai_request_log.request_id` (1:1), enforced via `recordAIRequest` helper which suppresses the PostHog capture on conflict-skip retries. No user content (`$ai_input`, `$ai_output_choices`) is ever captured.

## Alternatives considered

- **Custom PostHog events with `ai_request_completed` / `ai_request_failed`** (status quo ante). Rejected: would not feed PostHog's native LLM dashboards, would require bespoke dashboard construction, and would duplicate the cost-by-feature view that PostHog's LLM product gives for free.
- **Supabase-only dashboards (Grafana / Metabase on `ai_request_log`)**. Rejected: adds a new ops surface, misses the voice-session trace grouping, and doesn't naturally correlate with product-funnel events already in PostHog.
- **Client-side cost computation (iOS reads constants, does the math, emits `$ai_generation` directly for voice turns)**. Rejected: pricing-constant drift between iOS and backend is inevitable (iOS ships infrequently; backend updates hourly), violates the single-source-of-truth rule, and would require shipping constants via `/v1/config/bootstrap` anyway.
- **`/i/v0/ai` multipart endpoint with blob storage for `$ai_input` / `$ai_output_choices`**. Rejected on privacy grounds: Stir never captures user content to PostHog. The simpler `/i/v0/e/` JSON endpoint is sufficient when there are no blobs.
- **Per-Gemini-call `$ai_generation` granularity (each retry + replacement dish as its own event)**. Rejected to preserve 1:1 reconciliation with `ai_request_log` rows and avoid SSE-timing gymnastics. Retry granularity stays visible via the `retry_count` property on the aggregated event; slot-level cost is queryable from Supabase if ever needed.
- **`posthog-node` SDK in Deno Edge Functions**. Rejected: unknown Deno compatibility; raw HTTP `POST /i/v0/e/` is three lines, no dep, and matches our fire-and-forget pattern cleanly.

## Consequences

### Positive

- **PostHog LLM Analytics works for Stir out of the box.** Cost-by-feature, latency p95, error rate, and trace view all populate without any dashboard construction.
- **Voice sessions get session-scoped cost visibility** via a single close-time `$ai_trace` carrying input+output state, plus per-turn `$ai_generation` children that PostHog's pseudo-trace rollup aggregates automatically under the same `session_id`.
- **PostHog ↔ Supabase reconciliation is trivial.** `SELECT SUM(cost_usd) FROM ai_request_log GROUP BY feature_key` must match the PostHog cost-by-feature dashboard within ±1% (allowing for dropped PostHog events).
- **Privacy-safe by construction.** No user content enters PostHog at any layer of the pipeline; violating it requires a code change, not a config toggle.
- **`path: 'live_api' | 'gemini_fallback'` tag on voice events** lets dashboards split traffic between drivers without inspecting span names, matching spec §15's `cook_turn_resolved.path` semantics.

### Negative

- **Dual-write failure mode.** If the PostHog capture fails, the cost dashboard quietly under-reports while `ai_request_log` is correct. Mitigated by fire-and-forget semantics (the user's request never fails because PostHog is down) and `posthog_capture_non_2xx` warning logs, but ops needs to watch that log series.
- **Per-turn round-trip on voice** — iOS POSTs `/v1/ai/voice-turn-usage` after every `turnComplete` (~15 calls / session). Small (~200 B each, fire-and-forget), but it's a new backend endpoint to maintain.
- **PostHog's cost catalog doesn't know Gemini preview models** (`gemini-3-flash-preview` et al). Stir forwards `$ai_total_cost_usd` explicitly, so this works today — but if we ever want to use PostHog's auto-cost-compute feature, we'll need to register the model in their catalog.

### Tradeoffs

- **Voice adds a backend round-trip per turn to preserve 1:1 reconciliation.** Alternative (iOS captures directly) saves 15 POSTs per session but loses cost-constant provenance. The round-trip cost is cheap (fire-and-forget, ~50ms p95), the provenance win is permanent — accepted.
- **Accepting one `ai_request_log` row per HTTP request (not per Gemini call inside dinner-solve's retry loop)** loses retry granularity from PostHog. Retry cost IS visible via `retry_count` + `$ai_total_cost_usd` on the aggregated row, and the full per-call detail is still in Supabase if ever needed. Acceptable simplification.

## Notes

**Verification on first run:** one dinner-solve produces exactly one `$ai_generation` in PostHog with `$ai_trace_id = solve_request_id`; one 15-turn voice session produces 15 `$ai_generation` under the same `$ai_trace_id = session_id` + exactly one `$ai_trace` at close with BOTH `$ai_input_state` and `$ai_output_state` populated.

**Reconciliation SLA:** daily PostHog cost-by-feature vs `SELECT SUM(cost_usd) FROM ai_request_log WHERE created_at > now() - interval '1 day' GROUP BY feature_key` within ±1%. Anything worse is a PostHog-capture regression and needs investigation.

**Env vars added to Supabase Edge Function secrets:**
- `POSTHOG_PUBLIC_API_KEY` — same public key iOS uses (same trust tier as the anon key)
- `POSTHOG_HOST` — defaults to `https://us.i.posthog.com` if unset

**Files touched in this ADR:**
- `Backend/supabase/functions/_shared/posthog.ts` (new)
- `Backend/supabase/functions/_shared/ai_observability.ts` (new)
- `Backend/supabase/functions/voice-turn-usage/index.ts` (new)
- `Backend/supabase/functions/{pantry-parse,dinner-solve,substitution,recipe-import,grocery-generate,cook-turn,pgmq-dispatch,realtime-session}/index.ts` (modified)
- `Stir/Integrations/PostHog/PostHogClient.swift` (`captureAITrace` added)
- `Stir/Core/Services/AIDispatch.swift` (`voiceTurnUsage` added)
- `Stir/Core/Services/AIDispatchDTOs.swift` (`VoiceTurnUsageRequest` added)
- `Stir/Core/Services/SupabaseSessionClient.swift` (`performAuthenticatedNoContent` added)
- `Stir/Integrations/Speech/VoiceSessionDriver.swift` (`voiceSessionID` added to protocol)
- `Stir/Integrations/Speech/SpeechFallbackService.swift` (voiceSessionID conformance)
- `Stir/Integrations/GeminiLive/RealtimeSession.swift` (voiceSessionID conformance + `LiveTurnSummary` + per-turn POST in `finalizeTurn`)
- `Stir/Features/CookMode/CookModeRoot.swift` (wires `onTurnFinalized`)
- `Stir/Features/CookMode/CookModeViewModel.swift` (summary accumulator + `fireVoiceSessionCloseTrace`)

**Rejected in-progress designs (documented for history):**
1. Firing `$ai_generation` from iOS directly for voice turns, with pricing constants shipped via `/v1/config/bootstrap` — killed by the no-client-side-cost rule even though the drift risk is small.
2. A separate `voice_session_cost_total` product event at close — duplicated data PostHog's trace rollup already provides; rejected to avoid drift.
