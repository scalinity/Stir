# ADR 0021: Household context cached for 60 seconds on the Live mint path

- **Status**: Accepted
- **Date**: 2026-04-23
- **Owner-step**: Step 6 (voice)
- **Related**: P3-H / CA3-H5 from step-6 review 2026-04-23; `RealtimeSession.buildHouseholdContext`; ADR 0014 (session refresh every 4 turns); CLAUDE.md §Substitution hard-rule validator

## Context

`buildHouseholdContext` projects `HouseholdProfile` → `RealtimeHouseholdContext` on every Live mint (initial preWarm + every refresh, which fires every 4 turns per ADR 0014). For a Pro user with 1000 pantry items, the projection walks the full set on the MainActor on every refresh — observable CPU cost during a cadence refresh that's already on the critical path.

The substitution round-trip (`dispatchSubstitution`) builds its own context separately (P2-I / shared seam) and does NOT use this cache — it always pulls fresh. The substitution validator's hard-rule pass is correctness-critical per CLAUDE.md north-star constraint #5, and fresh pantry state is a non-negotiable input to that pass.

## Decision

Staleness tolerance for household context on the **Live mint path only** is 60 seconds, implemented via an in-memory TTL cache on `RealtimeSession`. The substitution path bypasses the cache and always re-projects. Cache is cleared in `close()`.

## Alternatives considered

- **No cache, always fresh** — Rejected: per-refresh MainActor walk at 1000-item pantry scale is measurable cost on a critical-path operation.
- **Invalidate via pantry-changed NotificationCenter signal** — Rejected: requires wiring a new notification into `PantryRepository` and every write-site. 60s TTL is simpler and the failure mode (user deletes a pantry item in another app, cook session picks up the stale view for ≤60s) is acceptable because no correctness decision in the Live system prompt depends on sub-minute pantry accuracy.
- **Cache with longer TTL (5 min)** — Rejected: approaches ADR 0014's 10-min session refresh cadence, meaning cache outlives the refresh cadence and never gets meaningfully invalidated.

## Consequences

### Positive

- Per-refresh MainActor walk eliminated on the hot path (saves N×pantry-size operations per Cook Mode session where N = refresh count).
- Substitution correctness invariant preserved: the hard-rule validator path bypasses the cache and always sees fresh pantry state.
- Cache clears on close, so a new Cook Mode entry always starts fresh.

### Negative

- Up to 60s of stale pantry view in the Live system prompt if the user edits pantry in another app mid-session. User-visible only if the model narrates pantry state contradicting the current CloudKit view.

### Tradeoffs

Substitution is the correctness-critical path (allergy safety); the mint system prompt is context-for-narration. The two have different staleness tolerances. Pinning the substitution path to fresh-always is the invariant that matters.

## Notes

- TTL value (60s) is tuned for "most users won't notice 60s-stale pantry in model narration" and can be raised if ops sees no user reports of pantry-stale narration at scale.
- Cache is instance-scoped on `RealtimeSession`; a new Cook Mode entry gets a new instance and a fresh cache.
