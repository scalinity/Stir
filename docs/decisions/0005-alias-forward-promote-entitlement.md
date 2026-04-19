# ADR 0005: stir_alias_forward promotes install→ck entitlement when ck has no row

- **Status**: Accepted
- **Date**: 2026-04-19
- **Owner-step**: Step 5 (billing + paywall)
- **Related**: `Backend/supabase/migrations/20260418000011_alias_forward_fn.sql` (original), `Backend/supabase/migrations/20260419000004_alias_forward_promote_entitlement.sql` (the fix), CLAUDE.md §"Aliasing when install:<id> gains CloudKit"

## Context

The original step-1 `stir_alias_forward` always DELETED install's `entitlement_snapshots` row on merge, on the assumption that ck would have its own entitlement (written earlier by the RC webhook). In practice, a common flow is:

1. User buys as `install:<uuid>` (no iCloud at purchase).
2. RC fires `INITIAL_PURCHASE`; webhook writes entitlement on install row.
3. User signs into iCloud.
4. `/v1/session/bootstrap` calls `stir_alias_forward(install, ck)` — deletes install's entitlement. ck has no row.
5. iOS calls `RC.logIn(ck:<record>)`; RC fires `SUBSCRIBER_ALIAS`.
6. Webhook calls `stir_alias_forward` again — no-op, install row is gone.

End state: user has paid entitlement on RC but NOT in Stir. Next bootstrap returns Free tier; user loses Premium silently.

## Decision

When the merge runs and ck has no entitlement row, PROMOTE install's row (UPDATE `canonical_user_key` install → ck) instead of deleting. When ck already has a row (the normal post-webhook case), keep ck + discard install ("ck wins when ck exists").

## Alternatives considered

- **Re-fire the RC webhook after merge** — rejected: doesn't work; RC doesn't support "replay this event please" and the iOS RC.logIn call doesn't trigger a new INITIAL_PURCHASE event.
- **Make iOS call `configBootstrap` after merge and trust it to eventually converge** — rejected: "eventually" depends on RC webhook timing, which the spec intentionally doesn't block on. Could be hours.
- **Always rewrite install's `canonical_user_key` to ck and never discard** — rejected: collides when ck already has an entitlement from prior activity (reinstall with same iCloud scenario).

## Consequences

### Positive

- Closes a silent data-loss path that was latent since step 1 and would have surfaced as "I bought Premium and it says I'm Free" support tickets.
- Idempotent: re-running `stir_alias_forward` after the promote is a no-op (install row no longer exists).
- Preserves ck-wins semantics when both rows exist.

### Negative

- Slightly more complex RPC logic — three branches instead of two.
- If the user's install-row entitlement is stale (e.g. webhook failure left it at `tier='free'`), promoting preserves the staleness. Next webhook delivery corrects it. Acceptable because the same staleness would have existed without the merge.

### Tradeoffs

- Adds one `IF EXISTS` branch and one `UPDATE` to the RPC. Measured impact on hot path: negligible (alias-forward is rare; runs once per identity change).

## Notes

- Regression test: `revenuecat_webhook_test.ts`'s "SUBSCRIBER_ALIAS moves entitlement from install → ck" exercises this path end-to-end.
- Migration 20260419000005 further wrapped the RPC in `stir_process_alias_webhook` to fix the idempotency TOCTOU surfaced in the step-5 review. ADR 0005 covers the promote semantics; the TOCTOU fix is considered an implementation detail of the same decision.
