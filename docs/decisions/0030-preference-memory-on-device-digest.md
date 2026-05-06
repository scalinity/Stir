# ADR 0030: Preference-memory loop computes the feedback digest on-device, sent transient in the dinner-solve request body

- **Status**: Accepted
- **Date**: 2026-05-06
- **Owner-step**: Step 4 (closing the post-cook feedback loop the OutcomeFeedbackView header has been promising since step-4 polish)
- **Related**: SCA-44, `Stir/Core/Services/PreferenceMemoryService.swift`, `Stir/Features/Solve/SolveViewModel.swift`, `Backend/supabase/functions/dinner-solve/index.ts`, `Backend/supabase/functions/_shared/validation.ts` (DinnerSolveRequest), `Backend/supabase/migrations/20260506000001_seed_dinner_solve_v2_preference_memory.sql`, CLAUDE.md §Tier-entitlements ("Preference memory window"), CLAUDE.md §Feature flags (`preference_memory_enabled`), spec §15 `dinner_solve_requested`, ADR 0009 (privacy posture), ADR 0014 (refresh-bounded growth — orthogonal but referenced for transient-context pattern)

## Context

`OutcomeFeedbackView` ("One tap. I'll learn for next time.") has captured rating + workload + taste + spice + wouldRepeat + leftoverCount + sanitized notes since step 4. Two of those fields actually loop back into the product today: `rating` sorts Saved meals, and `leftoverCount > 0` triggers Leftovers mode eligibility. The other four fields (workload, taste, spice, wouldRepeat) plus `notes` are write-only — they land in CloudKit and never influence future suggestions. `Backend/supabase/functions/dinner-solve/index.ts:404` hardcodes `feedback_json: null`. The `{{feedback_json}}` slot exists in the v1.0.0 prompt template but is never populated. CLAUDE.md tier entitlements list "Preference memory window: 30 / 90 / 365 days" as a designed-but-unbuilt feature.

North-star constraint #3 is non-negotiable: user content lives in CloudKit, not Postgres. The dinner-solve Edge Function runs server-side and has no access to CloudKit private databases. The loop has to close without violating that boundary.

## Decision

Compute the preference-memory digest **on-device** (`PreferenceMemoryService` reads `OutcomeFeedback` rows from the CloudKit-backed Core Data store, projects them into a bounded digest), and ship it as an optional `feedback_summary` field on the `/v1/ai/dinner-solve` request body. The Edge Function renders that digest into the `{{feedback_json}}` prompt slot, wraps it in USER_DATA fence markers (free-text `notes` are an injection vector), and gates the entire path behind a `preference_memory_enabled` server-side kill switch. The new prompt (`dinner_solve@2.0.0`) ships at `rollout_pct: 5` via the same deterministic-canary primitive (`pickStandardPrompt` mirrors `pickLeftoversPrompt`) so a regression on hard-rule pass / retry / latency doesn't take 100% of traffic.

## Alternatives considered

- **Postgres mirror of OutcomeFeedback** — write a thin row to `outcome_feedback_summaries` keyed on `canonical_user_key` whenever iOS upserts a rating, then have dinner-solve read from there. Rejected: violates north-star constraint #3 ("user content lives in CloudKit, not Postgres. Postgres holds operational metadata only"). Even an "aggregate-only" mirror is still derived user content — taste/spice/workload reveal household preferences that the constraint specifically protects.

- **Send raw OutcomeFeedback rows from iOS** — let the Edge Function aggregate. Rejected: a Pro user with 365 days of daily ratings ships ~800 rows × 100-200 tokens each; that's a 100k-token solve that obliterates the prompt budget and per-request cost model. Also pushes the tier-window enforcement (free 30d / premium 90d / pro 365d) onto the server, which has no clean way to verify the tier-claimed window matches the rows actually sent — a free user could over-share and the server has no source of truth to clamp.

- **CloudKit Web Services from the Edge Function** — Apple supports server-to-CloudKit auth via a service-token / signed-request pattern. Rejected: introduces Apple auth complexity into the AI hot path (every solve becomes a CloudKit round-trip + a Gemini round-trip), creates a new failure mode where Apple's CloudKit being down breaks dinner-solve, and the CloudKit private database is per-user — Edge Function would need to forge user identity for the read, which Apple's policy treats as the user's session, not a server identity. Net result: more vendors, more failure modes, no reduction in privacy surface area vs. on-device aggregation.

- **Bump v1.0.0 prompt to 100% with a feature-flag kill switch only (no canary)** — skip the `pickStandardPrompt` helper. Rejected: violates CLAUDE.md "When changing a prompt, bump prompt_versions.version semver and set rollout_pct conservatively (start at 5%)." The prompt template change includes a new "Recent feedback usage" instruction block that meaningfully alters model behavior on the same input shape — a regression on hard-rule pass rate is plausible enough that a canary is owed. Cost of `pickStandardPrompt` is ~50 lines mirroring an existing reviewed primitive (`pickLeftoversPrompt`).

- **Soften the OutcomeFeedbackView copy ("Saved to your meal history") and ship the loop later** — keep the surface honest while the loop is still queued. Rejected by Daniel — chose to ship the real loop. Pure prioritization call; no architectural objection.

## Consequences

### Positive

- The loop the user has been told exists since step 4 actually exists. Workload / taste / spice / wouldRepeat are no longer write-only fields.
- Same data path as `household_context` and `pantry`: transient request body, never persisted server-side. North-star #3 holds.
- Bounded payload (~600 prompt tokens) means a Pro user with 800 ratings sends the same request size as a Premium user with 40. Per-request cost is predictable.
- USER_DATA fence wrapping defeats free-text `notes` prompt injection — same defense as pantry display names, no new pattern.
- Server kill switch (`preference_memory_enabled`) gives ops a flip without an iOS rev. Failing-open on a flag-read glitch is fine because the data path is harmless on the v1.0.0 prompt (the slot already exists; populating it is a content distribution change, not a contract change).
- Canary at 5% via deterministic UUID hashing — same primitive as the leftovers v1.1.0 canary, so ops drift between the two paths stays minimal.

### Negative

- iOS now does work on every solve that wasn't there before: a CoreData fetch of up to 100 sessions + projection. Best-effort — a CoreData read failure surfaces as digest=nil and the solve proceeds, but the read is on the solve hot path. Mitigated by the relationship-prefetch already in `recentCompletedSessions` (no N+1 traversal of `outcomeFeedback`).
- The wire schema for `feedback_summary` is a new contract that iOS and backend must keep in lockstep. Drift = VAL-01. Sizes pinned in both `PreferenceMemoryService.recentMealsCap` (etc.) and the Zod max counts; tests on either side would catch drift before prod, but the maintenance burden is real.
- Tier window (30/90/365) is enforced on iOS only. A jailbroken / patched build could send a 365-day window claiming free tier. Acceptable — the worst outcome is a "free" user gets a richer prompt context, which costs us a few extra tokens per solve, not a security or privacy boundary.

### Tradeoffs

- We pay ≤600 prompt tokens per solve in exchange for a meaningful preference signal in the model's input. At Free 6 solves/mo and Pro 120 solves/mo with `gemini-3-flash-preview` text-input pricing of $0.50/1M tokens, this adds ≤$0.0009/mo at the heaviest tier. Negligible vs the ARPU contribution of the feature.
- Putting the kill switch defaults to ON (failing-open on flag-read failure) is a deliberate call: failing-closed would mean every Postgres glitch on the flags table silently strips the feature for an unknown duration, which we'd debug from the iOS funnel instead of from the flag dashboard. Failing-open trades a slightly worse failure mode (transient prompt regression) for one we can detect immediately (`feedback_summary_present` rate drop in `dinner_solve_requested`).

## Trigger to revisit (n/a — Accepted)

n/a. If the on-device digest path proves too token-heavy or the regression story for v2.0.0 is bad enough to keep the canary stuck below 100%, a revision (or a follow-up ADR) replaces this one.

## Notes

- The same digest surface should extend to substitution and cook-turn fallbacks. Out of scope for the SCA-44 PR — substitution doesn't need 90 days of taste history to swap chicken for tofu, and the voice-cook flow has its own context budget that needs separate cost-model work before adding new content. Tracked in `docs/deferred-work.md` (preference-memory loop fan-out).
- Promotion to 100%: once the v2.0.0 canary shows no regression on hard-rule pass rate, retry rate, or latency, a follow-up migration flips `is_default` from v1.0.0 → v2.0.0 and raises rollout_pct to 100. `pickStandardPrompt` becomes a transparent passthrough on that day — by design, no code change required.
- Spec §15 `dinner_solve_requested` gains `feedback_summary_present: bool` and `recent_meal_count: int`. Funnel splits — "did the loop even have data to feed in?" — are the fastest signal that a Free→Premium tier-window cliff is hurting conversion; if upgrade conversion correlates with `feedback_summary_present=true` more than tier alone, the windowing policy is doing real work.
