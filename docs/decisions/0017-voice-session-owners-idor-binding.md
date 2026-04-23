# ADR 0017: voice_session_owners — bind session_id to canonical_user_key with supersede-on-mint lifecycle

- **Status**: Accepted
- **Date**: 2026-04-23
- **Owner-step**: Step 6 (voice)
- **Related**: P1-B / SA2-W4 from step-6 review 2026-04-23; migration `20260423000003_voice_session_owners.sql`; `realtime-session` handler; `voice-turn-usage` handler; `_shared/errors.ts` (`VoiceSessionReason`); CLAUDE.md §AUTH-01 response shape (the `reason` field pattern this mirrors); ADR 0014 (session refresh)

## Context

Before this ADR, `/v1/ai/voice-turn-usage` verified the caller's JWT and re-checked `voice_enabled`, but did not verify that the `session_id` in the request body was actually minted by the authenticated user. A Premium client — forged, compromised, or buggy — could POST turns under any `session_id` UUID and have them attribute to THEIR own `ai_request_log` rows. Bounded blast radius (no cross-user cost attribution), but a targeted attacker who read another user's `session_id` off a logged response body (see ADR 0016's historical SA2-W1 finding on setup_frame echoing) could pollute that user's `$ai_trace` rollup in PostHog via the shared-trace-id semantics.

Gemini Live has no server-side logout. The mint endpoint generates a fresh `session_id` on every call (including refreshes per ADR 0014). With no backend record of "which user owns which session," there's no surface to gate per-turn posts.

## Decision

Introduce `voice_session_owners(session_id PK, canonical_user_key, minted_at, closed_at)`. Every mint call writes a new row with `closed_at = NULL`. Before the INSERT, the handler UPDATE-closes any prior open rows for the same `canonical_user_key`, enforcing at most one open session per user at a time. `/v1/ai/voice-turn-usage` consults this table on every request and rejects with three distinct typed reasons:

- `session_missing` → no row (mint never happened, or 2h retention purged it) → 403 `ENT-VOICE-01`.
- `owner_mismatch` → row exists but `canonical_user_key` ≠ authenticated caller (IDOR) → 403 `ENT-VOICE-01`.
- `session_closed` → row exists, owner matches, but `closed_at IS NOT NULL` (superseded by a newer mint) → 403 `AI-VOICE-01`.

Table is deny-all RLS; retention cron purges rows > 2h old.

## Alternatives considered

- **Store owner on `ai_request_log`** — Avoids a new table. Rejected: the mint's log row is keyed on a client-generated `request_id`, not `session_id`; retrofitting either a lookup index or a new column is similar-cost to a dedicated table and less self-documenting.
- **Binary model (no `closed_at`)** — Simpler: row present = owned, missing = rejected. Rejected because it collapses the IDOR signal and the "stale client session_id" signal into one error, making ops dashboards unable to distinguish attack traffic from users with in-flight posts across a refresh swap. The `closed_at` column costs one column + one partial index for a first-class lifecycle signal.
- **No ownership check; rely on per-row `trace_id` contamination being bounded** — Rejected because CLAUDE.md's security posture is "every `/v1/*` endpoint Zod-validates, every ops table RLS-gates, every authenticated path binds to `canonical_user_key`." Leaving `session_id` as a bearer-token-like client assertion breaks the uniformity.

## Consequences

### Positive

- Closes SA2-W4 IDOR without introducing new error codes: reuses `ENT-VOICE-01` / `AI-VOICE-01` with typed `VoiceSessionReason` in the existing `reason` field.
- First-class `session_closed` signal lets ops distinguish "stale client" from "hostile client" without log-text parsing.
- Table stays tiny (≤ 1 row per active session per user; retention 2h).
- iOS side unchanged — the rejection surfaces as a normal 403 the VM already handles.

### Negative

- New handler-side write on every mint (two queries: UPDATE supersede + INSERT new). ~20-40ms added to mint latency; acceptable on a path that already does ~500ms of Gemini round-trip.
- One more table to monitor. RLS default-deny + partial index keeps operational burden low.
- Test harness needs a `seedVoiceSessionOwner` helper for any test that bypasses the mint endpoint.

### Tradeoffs

The table and the supersede logic are the minimum viable fix for the IDOR class. Stronger designs (HMAC-signed session_id cookies bound to JWT claims, for example) would be cryptographic rather than relational, and add key rotation runbooks without meaningfully narrowing the threat model at current scale. Revisit if attack volume ever justifies moving to signed tokens.

## Notes

- Supersede UPDATE fires inline, not `waitUntil`, because iOS's first turn POST can race the write. A 20ms serial cost on mint beats a race that admits an old-session POST between mint and supersede-commit.
- `VoiceSessionReason` lives in `_shared/errors.ts` as a typed widening of the existing `reason` field; keeps iOS's error-handling surface uniform with AUTH-01's pattern.
- Three smoke tests gate the deploy: (1) cross-user IDOR → `owner_mismatch`; (2) mint + supersede + POST-on-old-session → `session_closed`; (3) POST on unminted UUID → `session_missing`.
