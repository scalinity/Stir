# ADR 0008: Voice temporarily free for testing (step-6 dev build only)

- **Status**: Superseded by [ADR 0015](./0015-voice-cap-reduction-and-live-caching-finding.md) on 2026-04-23
- **Date**: 2026-04-22
- **Owner-step**: Step 6 (voice)
- **Related**: CLAUDE.md §North-star constraints #6 ("Voice is Premium+ only"), CLAUDE.md §Tier entitlements, `Backend/supabase/functions/_shared/entitlements.ts`, ADR 0004 (entitlement source of truth), [ADR 0015](./0015-voice-cap-reduction-and-live-caching-finding.md) (supersession)

## Revert record (2026-04-23)

Reverted in the post-device-test release per ADR 0015:

- `TIER_CAPS.free.voice_cook_session`: 20 → **0** (back to CLAUDE.md north-star #6)
- `TIER_CAPS.premium.voice_cook_session`: 20 → **13** (ADR 0015 cap cut, not a revert)
- `TIER_CAPS.pro.voice_cook_session`: 40 → **27** (ADR 0015 cap cut, not a revert)
- Prod secret `ENTITLEMENT_OVERRIDE_VOICE_FREE` unset (was `true` during step 6)

The iOS companion changes documented below (EntitlementService honoring server-computed `voice_enabled`, `quota.cap > 0` guard in metered checks) are **permanent** and not part of the revert — they were correctness fixes the ADR-0008 work surfaced, not ADR-0008-specific behavior.

`effectiveVoiceEnabled()`'s `ENTITLEMENT_OVERRIDE_VOICE_FREE` env escape hatch is kept in the code for future testing/dev/staging runs; prod must leave the secret unset. Runbook: before any cap-related deploy, `supabase secrets list --project-ref ktqajarcomzplnpbczfo` must show the env absent.

## Context

Step 6 needs hands-on iteration against real Gemini Live sessions from Daniel's iPhone. CloudKit identity resolution is intermittent on dev builds — bootstrap frequently falls back to `install:<uuid>` keys even when iCloud is signed in — so the CK-keyed Premium row (`ck:_ac401446e1c5b081575a37ee713977e8`) doesn't consistently get used. Every fallback install starts at Free tier with `voice_cook_session` cap=0, which means `effectiveVoiceEnabled()` returns false and `realtime-session` returns `ENT-VOICE-01` before any WebSocket code runs. Per-install DB promotions don't survive reinstall. The paywall is working (ADR-001 style gate verified); it's just the wrong surface during voice iteration.

## Decision

Temporarily override `effectiveVoiceEnabled()` to return `true` for all tiers, and raise `TIER_CAPS.free.voice_cook_session` from 0 to 20, while step 6 is in active development. The backend override is a single-point change in `Backend/supabase/functions/_shared/entitlements.ts`, clearly marked with `// TEMPORARY ADR-0008` comments so a grep finds every touchpoint.

**iOS companion changes (permanent, not revert-coupled):**

1. `EntitlementService.canAccess(.voiceCookMode)` previously hardcoded `effectiveTier == .free → blocked`, diverging from the server-computed `voice_enabled` flag and violating CLAUDE.md rule "Don't derive `voice_enabled` on iOS." That gate now honors `voiceEnabled` from the bootstrap response, matching all other voice-related surfaces.

2. All three metered quota checks (`voiceCookMode`, `dinnerSolve`, `recipeImport`) now require `quota.cap > 0` before triggering `.blockedByQuota`. The prior `quota.used >= quota.cap` check incorrectly fired `0 >= 0 = true` when a stale cached snapshot had `cap=0` (e.g., bootstrap cached before a tier change or before the ADR-0008 cap bump) — blocking the user even though they hadn't consumed anything. Server-side comment in `readQuotasForWire` flags this exact footgun; the server never emits cap=0 anymore, but the client shouldn't assume that.

Both are correctness fixes regardless of ADR-0008 and should NOT be reverted on revert day — the originals were latent bugs.

## Alternatives considered

- **Promote Daniel's current install row in the DB** — one SQL UPDATE to `entitlement_snapshots` keyed on `install:B8D1DE97-…`. Rejected because it doesn't survive reinstall, simulator wipe, or a second test device, and it leaves every test session one step away from tripping `voice_cook_session` RATE-01 (cap still 0 on the usage row unless separately patched).
- **Fix CK identity resolution now so `ck:_ac401…` is picked up reliably** — the correct long-term fix, but it's its own investigation (why isn't `CKContainer.accountStatus` returning `.available` consistently on dev builds?). Doing it under time pressure while voice is mid-iteration risks a secondary bug blocking the primary work.
- **Add a `voice_testing_override` feature flag in `feature_flags`** — cleaner architecturally, but requires a migration, wiring, and client/server alignment for a ~1-week window. Overkill.
- **Leave the paywall in place; manually top up the specific install's `entitlement_snapshots` + `usage_counters` rows for each test session** — brittle, error-prone, and the exact kind of manual ops work that slows iteration.

## Consequences

### Positive

- Unblocks step 6 end-to-end voice testing from any iPhone, install, or simulator.
- Zero iOS changes — the client-side gate continues to honor the server response verbatim, so no test artifacts leak into shipped code.
- Revert is a single commit plus a `supabase functions deploy` of two functions.

### Negative

- **North-star constraint #6 is suspended until revert.** Any marketing, paywall, or revenue test run against this build will misreport Free-tier behavior. Do NOT run beta paywall validation, RevenueCat webhook drills, or Premium-conversion eval traffic against the overridden prod backend.
- `voice_cook_session` metering is effectively off for Free users on prod during this window. `ai_request_log` still captures cost, so true cost is recoverable, but the quota-enforcement path is untested.

### Tradeoffs

- Short-term velocity on voice > short-term correctness of the entitlement boundary. The boundary has test coverage (`CookModeVoiceIntegrationTests`, entitlement unit tests) and the ck-keyed path is unchanged; only the effective-tier compute is overridden.

## Trigger to revisit (revert gate)

Revert this ADR (and the code changes) when ANY of the following are true:

1. Step 6 Phase D.1 validation gate passes — TTFA(normal) p95 < 500 ms AND TTFA(tool_call) p95 < 1500 ms (per the ADR 0012 gate split; supersedes the original "TTFA p95 < 1.0s" merged gate), preamble rate ≥ 70 %, pruning holds, session refresh silent. Voice is production-ready and gating must return.
2. Beta prep starts (step 9) — absolute deadline; cannot ship beta with voice paywall disabled.
3. Any RevenueCat webhook or paywall-conversion eval run is scheduled.
4. Weeks-of-elapsed-time ≥ 4 from this ADR's date. Testing windows drift; hard deadline prevents indefinite override.

Revert procedure (fast path — env flag):

1. `supabase secrets set ENTITLEMENT_OVERRIDE_VOICE_FREE=false --project-ref ktqajarcomzplnpbczfo` — flips the override off without a code change.
2. `cd Backend && supabase functions deploy session-bootstrap config-bootstrap realtime-session cook-turn --project-ref ktqajarcomzplnpbczfo` — redeploy so functions pick up the new env.
3. `UPDATE usage_counters SET cap_count = 0 WHERE feature_key = 'voice_cook_session' AND canonical_user_key NOT IN (SELECT canonical_user_key FROM entitlement_snapshots WHERE tier IN ('premium','pro') AND billing_state IN ('active','trial','grace','cancelled_active'));` — restores cap=0 on Free rows while leaving paid users intact.
4. Flip ADR status to `Superseded by revert` with a forward link to the revert commit.

Revert procedure (full — for when the ADR is permanently retired):

1. Follow the env-flag revert above to flip behavior off immediately.
2. In a follow-up PR: remove the `ENTITLEMENT_OVERRIDE_VOICE_FREE` branch from `effectiveVoiceEnabled()`, restore `TIER_CAPS.free.voice_cook_session` to 0, delete the secret via `supabase secrets unset ENTITLEMENT_OVERRIDE_VOICE_FREE`.

## Notes

- The override lives in `entitlements.ts` so it applies uniformly across `session-bootstrap` (surfaces `voice_enabled` in the response), `config-bootstrap` (refresh path), `realtime-session` (mint gate), and `cook-turn` (text fallback gate). A single point of truth prevents drift.
- CK-resolution bug is real and will need its own investigation before beta. Logged informally; not filed as a task yet.
- Daniel's ck row (`ck:_ac401446e1c5b081575a37ee713977e8`) remains tier=premium, billing=active through 2026-12-31 regardless of this override — it's a belt-and-suspenders path, not a dependency.
