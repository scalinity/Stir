# Runbook: cost anomalies — `resolved_at` semantics

Companion note to [`cost-anomaly.md`](./cost-anomaly.md), which covers
detection thresholds, cadence, kill-switches, and Sentry DSN config.
This file documents the **`resolved_at` invariant** introduced by
SCA-303, which silently flipped the dedup contract from a time-windowed
re-emit to a storage-level "at most one open row per grain — forever."
Operators reading the legacy section in `cost-anomaly.md` will see the
old 24h dedup language; this file is the authoritative source.

## Triaging an anomaly

**Always set `resolved_at` after triage — leaving NULL silently suppresses
future detection of the same type for that user.** SCA-303 traded the
legacy 24h re-emit window for a storage-level UNIQUE INDEX on
`(canonical_user_key_hash, anomaly_type) WHERE resolved_at IS NULL`. An
unresolved row of the same grain blocks all future inserts of that
grain forever. Pre-SCA-303 behavior — `stir_ops_cost_anomaly_scan`
re-emitting after 24h via a NOT EXISTS subquery on `detected_at` — was
removed because the subquery race let two scanner invocations both
decide "no recent dupe" and insert twice; the partial unique index
closes that race at the storage layer but trades back the time-based
re-emit. The operator side of the trade is that `resolved_at` is now
load-bearing.

When triaging via the ops console:

1. Open the anomaly in the Cost Anomalies page.
2. Walk the user-detail / `ai_recent` evidence per `cost-anomaly.md`'s
   "Triage" section.
3. Choose an action (confirmed abuse → ban; product bug → file +
   kill-switch; false positive → resolve; spend tuning → migration).
4. **Set `resolved_at`** on the row. The ops console's "Mark reviewed"
   action stamps `resolved_at = now()` — verify the row's
   `resolved_at` is non-NULL before closing the page. If you patched
   via raw SQL, run:

   ```sql
   UPDATE public.cost_anomalies
      SET resolved_at = now(),
          resolution_note = '<one-liner: false-positive | banned | kill-switched | tuned>'
    WHERE id = '<anomaly-id>'
      AND resolved_at IS NULL;
   ```

   Future scans for the same `(user_hash, anomaly_type)` only re-emit
   after `resolved_at` is set; leaving NULL means the next genuine
   spike for that user/grain is invisible.

## Grains

Two grains carry meaningfully different operator expectations. Both
share the same `resolved_at` invariant.

| Grain | `anomaly_type` values | Granularity |
| --- | --- | --- |
| Daily-spend | `daily_spend_2x`, `daily_spend_hard_cap` | Per-user per-day spend over thresholds |
| Per-session voice | `voice_session_tokens_over_cap`, `runaway_session` | Per voice session (grouped by `session_id` extracted from `request_id=voice:<sid>:<turn>`) |

A user can simultaneously have one open row per type — the partial
unique index keys on `(canonical_user_key_hash, anomaly_type)`, so a
`daily_spend_2x` row at NULL `resolved_at` doesn't block a
`voice_session_tokens_over_cap` row from inserting.

## Reference

- Migration: `Backend/supabase/migrations/20260510221200_cost_anomalies_partial_unique_index.sql`
- Thresholds + detection cadence + Sentry DSN setup: [`cost-anomaly.md`](./cost-anomaly.md)
- Spec: `Specs/Stir-Full-Spec.md` §13 (cost detection)
