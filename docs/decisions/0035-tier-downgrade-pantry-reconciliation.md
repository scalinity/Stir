# ADR 0034: Tier-downgrade pantry reconciliation — soft-archive `(used - cap)` oldest remembered rows to ephemeral

- **Status**: Accepted
- **Date**: 2026-05-08
- **Owner-step**: Pre-public-launch chrome polish (before public launch); implement when first user reports the "200 of 25" anomaly OR pre-public-launch chrome polish, whichever first
- **Related**: SCA-99, SCA-100, ADR 0028 (pantry-management surface), ADR 0029 (pantry auto-consume), CLAUDE.md §Tier entitlements ("Remembered pantry items"), `EntitlementService.applyTierChange`, `PantryItemRepository`, `Stir/Features/Pantry/PantryListView.swift`, Specs §15 telemetry

## Context

A user trials Premium, accumulates 200 `.remembered` `PantryItem` rows (cap 250 ✓), trial expires → tier downgrades to `.free` (cap 25). The 200 existing rows persist; new adds reject with `.capReached`; the Pantry header reads "200 of 25 saved" — visually broken, semantically inconsistent with cap-enforced add behavior.

ADR 0028 placed the pantry surface under Settings but did not prescribe what happens to over-cap remembered inventory on tier downgrade. This is a real edge case that surfaces during every Premium → Free transition: trial expirations, voluntary cancellation that runs to `expired`, and grace-period transitions that resolve into `expired` rather than `active`.

The choice is between (A) reconciling on downgrade so cap math always holds, vs (B) grandfathering existing rows and accepting a permanently inconsistent header until the user manually deletes the excess.

## Decision

On tier-downgrade hydrate, the `EntitlementService.applyTierChange` hook invokes `PantryItemRepository.reconcileForTierChange(newTier:)`. The repository soft-archives the **oldest `(used - cap)` `.remembered` rows to `.ephemeral`** (ordered by `lastSeenAt asc, createdAt asc` — fall back to `createdAt` when `lastSeenAt` is nil). Reconciled items are not deleted; they remain in CloudKit and inherit standard `.ephemeral` lifecycle (auto-consume on cook completion per ADR 0029, no expiration enforcement, hidden from the Pantry header count).

A non-blocking in-app banner explains the transition: "Your X oldest pantry items are now temporary. Re-upgrade to Premium to make them permanent again." Banner dismissed manually or auto-dismisses after 7 days.

Telemetry: new event `pantry_tier_downgrade_reconciled` with properties `{previous_tier, new_tier, archived_count, total_remembered_pre, total_remembered_post}`. Adds to spec §15 + CLAUDE.md telemetry index in the implementing PR.

## Alternatives considered

- **Option B: Clamp header display + grandfather rows** — clamp the header to `min(used, cap)`, document Free-grandfathering in copy ("you keep what you had, but new adds need Premium"), surface a "Manage pantry" prompt. **Rejected because:**
  1. The header would lie about the underlying state (header reads `25/25` while 200 items exist), which contradicts every other place in the app where counters reflect storage truth.
  2. The cap-enforced add behavior contradicts the "grandfathered" framing — adding a single new item still rejects with `.capReached` until the user manually deletes 175 items. That's friction without a corresponding payoff.
  3. The ambiguity propagates into reconciliation downstream — grocery diff, scan dedup, auto-consume all need to know which items "count" against the cap. Option B forces every downstream consumer to re-implement the clamp.
  4. Option A's reconciliation runs once at downgrade time; Option B carries the inconsistency forever (or until user-initiated cleanup).

- **Option C: Hard-delete `(used - cap)` oldest rows** — silently delete the oldest excess rows on downgrade. **Rejected because** it permanently destroys user data on a billing event, and re-upgrading to Premium can't recover the deleted state. Soft-archive to `.ephemeral` preserves the data.

## Consequences

### Positive

- Cap math is always consistent with header display and add-rejection behavior.
- Re-upgrade path is data-recoverable: `PantryItemRepository.reconcileForTierChange(newTier: .premium)` can promote the most-recently-archived `.ephemeral` rows back to `.remembered` if the user re-upgrades within a reasonable window. (Implementation can land in a follow-up; the data is preserved either way.)
- Telemetry on the reconciliation event surfaces downgrade volume, archive sizes, and re-upgrade behavior, which feeds the cohort-math sensitivity check in spec §9.
- Eliminates the "200 of 25" anomaly Daniel flagged in SCA-99 without leaving downstream consumers to defensively re-clamp.

### Negative

- New repository API + invocation hook + telemetry event + UI banner — not a one-line fix. Estimated 80–150 LOC across `PantryItemRepository`, `EntitlementService`, `PantryListView`, plus tests.
- Behavior change feels surprising the first time a user encounters it ("my pantry shrunk"). Mitigated by the in-app banner copy and (future) re-upgrade restoration. Banner copy needs review against existing pantry-empty-state mockup grammar before ship.
- Reconciliation must be idempotent and re-entrant: a tier-flap (Premium → Free → Premium within minutes during webhook retry storm) cannot double-archive or strand items in `.ephemeral` that should still be `.remembered`. Implementation must check current tier at run time, not blindly trust the hydrate event payload.

### Tradeoffs

- Trading one-time reconciliation complexity for permanent UI/state coherence. The complexity is bounded (one repository method, one banner) and runs at a low-frequency event (tier downgrade). The alternative is permanent ambiguity — every downstream pantry consumer carries a "but is it really over-cap?" branch forever.

## Trigger to revisit

Three signals reopen this decision:

1. **Re-upgrade restoration UX validates poorly** — if telemetry shows users on the upgrade path expect their archived items to auto-promote and they don't (or vice versa), the restoration policy needs a separate ADR.
2. **Tier-flap rate exceeds 1% of webhooks** — if RevenueCat retry storms cause real tier-flap reconciliation collisions in production, the idempotency design needs revisiting (likely by serializing through a single `app_users.pantry_reconciliation_lock` advisory lock per canonical key).
3. **Banner dismissal rate < 30% within 7 days** — if users don't see / don't understand the banner, the copy and surface need redesign. (Default soft-dismiss at 7d means the banner stops mattering; if engagement is below threshold, that's evidence the explanation never landed.)

## Notes

- **No schema migration required.** `PantryItem.lifecycleState` enum already supports `.remembered` and `.ephemeral`. The reconciliation is a pure CloudKit row update.
- **No backend coordination required.** Cap source-of-truth is `EntitlementService.standingPantryCap` (post-SCA-100). The repository reads the cap from the entitlement service at reconciliation time; no Edge Function call.
- **Order of operations on downgrade**:
  1. RevenueCat webhook → `entitlement_snapshots` updated server-side.
  2. iOS `/v1/config/bootstrap` returns new tier on next foreground.
  3. `EntitlementService.applyTierChange` detects the tier delta.
  4. `PantryItemRepository.reconcileForTierChange(newTier:)` runs synchronously — must complete before the `EntitlementService` publishes the new tier to observers, otherwise `PantryListView` renders a frame at the broken `200/25` state.
- **Re-upgrade restoration is out of scope for this ADR** — the data preservation guarantee is locked here; the promote-back UX can be designed separately when (or if) telemetry shows the demand. Soft-archive guarantees the option exists.
