# 0036 — Rate-limiter fail-open vs fail-closed posture per endpoint

**Status:** Accepted
**Date:** 2026-05-14
**Tickets:** SCA-373 (session-bootstrap fail-closed), SCA-391 / SCA-396 (this ADR — explicit per-endpoint posture)
**Supersedes:** N/A

## Context

`stir_rate_limit_check` (Postgres RPC, `_shared/rate_limiter.ts`) is called from every `/v1/*` handler before the work the rate limit gates. The RPC can throw on transient infra issues (Postgres conn-pool exhaustion, brownout, mid-deploy) — what should each handler do?

SCA-373 flipped `session-bootstrap` to fail-CLOSED with `503 NET-01 + Retry-After: 30` because it's the only **pre-auth** endpoint and a sustained DB blip would otherwise let an attacker mint unlimited bootstraps (the entire DoS surface SCA-247's IP rate limit was added to close). The 11 sibling handlers (post-auth) still fail-OPEN — they swallow the throw and continue.

The asymmetry is correct but reads as inconsistency. A future contributor diffing the two and noticing the difference might "fix" it the wrong way (apply fail-closed to a billable post-auth endpoint and lock active users mid-cook, or apply fail-open to a future pre-auth endpoint and re-open the bypass). This ADR pins the per-endpoint reasoning so the asymmetry stays intentional.

## Decision

**Per-endpoint posture (explicit):**

| Handler | Posture | Rationale |
| --- | --- | --- |
| `session-bootstrap` | **fail-CLOSED** | Pre-auth. IP rate limit is the only DoS defense against synthetic-install JWT-farming (SCA-247 + SCA-373). DB blip → unlimited bootstraps → unlimited JWT mints. 503 NET-01 + Retry-After is the right floor; iOS treats NET-01 as transient transport failure and silent-retries. |
| `push-register` | fail-OPEN | Post-auth. Locking active users out of push-prefs updates mid-cook is worse UX than letting through a few extra POSTs. Server is idempotent; per-IP cap (`push_register_hourly = 20`) is spend-control, not DoS-bound. |
| `dinner-solve` | fail-OPEN | Post-auth + billable. Fail-closing during a DB blip would deny legitimate users mid-cook on the Free-tier 6/day cap. Per-user + per-IP caps already protect against runaway spend on the happy path; transient bypass during a brownout is contained by the surrounding entitlement gate (Free tier checks). |
| `realtime-session` | fail-OPEN | Post-auth + billable + paid-tier (Premium/Pro). Same reasoning as dinner-solve; the entitlement gate ahead of the rate-limit catches Free-tier abuse first. |
| `cook-turn` | fail-OPEN | Post-auth + billable + ALWAYS mid-cook. Lock-out during an active Cook Mode session is the worst possible UX — voice fallback, substitution, etc. all flow through here. |
| `substitution` | fail-OPEN | Same as cook-turn — mid-cook rescue path; failure denies the user a working substitute. |
| `recipe-import` | fail-OPEN | Post-auth + billable. Per-IP daily cap absorbs the abuse case; user-visible "import failed during outage" is acceptable. |
| `grocery-generate` | fail-OPEN | Post-auth. Low spend per call; locking out grocery generation during a DB blip is needless friction. |
| `pantry-parse` | fail-OPEN | Post-auth + billable + ALWAYS user-initiated (camera shutter). User just took a photo; failing it during a brownout asks them to re-shoot. Spend cap is daily not minutely. |
| `voice-turn-usage` | fail-OPEN | Post-auth + observability-only (writes to ai_request_log; no Gemini call). Fail-closing here loses telemetry for a real voice session in flight; fail-open just risks an extra observability write. |
| `users-delete-request` | fail-OPEN | Post-auth + write-once. Per-user-per-day cap; one extra row written during a brownout is the worst case. |
| `ops-admin` (per-route) | fail-OPEN | Post-auth + admin-scoped. Locking out ops console during an incident is the opposite of what we want when triaging. Two layered gates (IP + per-admin) backstop. |

**Future contributors:** if you add a new `/v1/*` endpoint, default to **fail-OPEN** unless the endpoint is **pre-auth** (no JWT verify) AND a transient DB blip would unlock a measurable abuse surface. Pre-auth + abuse-surface is the SCA-373 trigger; everything else inherits the post-auth fail-open default.

If a fail-open post-auth endpoint ever becomes a real abuse vector (e.g. dinner-solve cap bypass during brownouts becomes load-bearing for spend control), revisit by:
1. Adding per-canonical-user dedupe in the limiter scope (so abuse is bounded even when the limiter itself is unavailable).
2. Tier-up to fail-CLOSED only for that endpoint, with a typed NET-01 + Retry-After response (matching SCA-373 wire shape).

## Considered alternatives

**(a) Fail-CLOSED everywhere.** Locks billable + mid-cook endpoints during a DB blip — denies every active user. Rejected: UX cost dominates the spend-bypass risk on post-auth endpoints.

**(b) Fail-OPEN everywhere (revert SCA-373).** Re-opens the synthetic-install JWT-farming surface that SCA-247 + SCA-373 closed. Rejected: pre-auth bypass is the worst class of abuse vector — no entitlement gate behind it to catch the spillover.

**(c) Per-endpoint config flag.** A `feature_flags`-driven knob to flip posture without code change. Rejected: too many knobs for too little payoff; the per-endpoint reasoning is stable and codified in this ADR.

## Consequences

- Each fail-open handler carries an inline `// SCA-396: fail-open is intentional — see ADR 0036` comment so a future "fix" PR can't silently flip the posture without touching the ADR.
- The single-call-site fail-CLOSED in session-bootstrap stays as the canonical example of the alternative posture (with its own SCA-373 docstring).
- New endpoints inherit the default-fail-OPEN convention by precedent; this ADR is the place to document any deviation.
