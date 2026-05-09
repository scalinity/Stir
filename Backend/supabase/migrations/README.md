# Stir migrations — local discipline

This README documents the conventions Stir migrations follow on top of Supabase's defaults. Read `CLAUDE.md` §"Schema truth" + §"Immutable-migration policy" first; this file is a quick reference, not the authoritative source.

## Naming

```
YYYYMMDDHHMMSS_kebab-short-description.sql
```

The leading 14-digit timestamp determines apply order. Supabase CLI sorts lexicographically, so leading-zero-padded timestamps are mandatory.

## SCA-268 / SCA-282 — Unique-per-second discipline

Every new migration MUST land at a timestamp at least one second past the previous migration. Use `date -u +%Y%m%d%H%M%S` immediately before staging the new file. If two ticket trains are landing on the same day, the second one bumps to the next free second — even if the body would have been valid at the same timestamp. This is non-negotiable for fresh-init correctness, not just lexical-order hygiene.

### Why same-second collisions are not commutative-safe

`supabase_migrations.schema_migrations` has a primary key on `version` alone. When two migration files share a 14-digit prefix, both bodies execute successfully but the second `INSERT` into `schema_migrations` fails with `23505 duplicate key value` and rolls back the entire `supabase start`. The collision fires regardless of whether the bodies are commutative — the bookkeeping table itself can't tolerate duplicate version rows.

Prod environments don't see this because rows were inserted one-at-a-time as the migrations landed; the collision only triggers when the CLI applies a same-second pair in a single batch (fresh `supabase start` / `db reset`).

### History — the three collision pairs that bit us

`2026-05-08` had three same-second pairs land via parallel agents:

- `20260508000006_deletion_fulfill_cron.sql` + `20260508000006_pgmq_dispatch_secret_via_vault.sql`
- `20260508000007_pgmq_dispatch_5field_schedule.sql` + `20260508000007_stir_claim_deletion_requests.sql`
- `20260508000008_deletion_request_sla_alerts.sql` + `20260508000008_drop_deletion_requests_completed_at.sql`

SCA-268 originally documented these as "safe to leave because they're commutative." That reading was empirically wrong — see "Why same-second collisions are not commutative-safe" above. Fresh `supabase start` failed at the first pair (`20260508000006`) post-SCA-280's prompt-versions partial-unique-index fix. Filed as SCA-282.

### How SCA-282 resolved them

Per the **correctness-blocks-fresh-init exception** in `CLAUDE.md` §Schema truth, one file in each pair was renamed to a fresh version timestamp:

- `20260508000006_pgmq_dispatch_secret_via_vault.sql` → `20260508000061_pgmq_dispatch_secret_via_vault.sql`
- `20260508000007_pgmq_dispatch_5field_schedule.sql` → `20260508000071_pgmq_dispatch_5field_schedule.sql`
- `20260508000008_drop_deletion_requests_completed_at.sql` → `20260508000081_drop_deletion_requests_completed_at.sql`

Each renamed file kept its body byte-identical; only the filename's timestamp changed. The kept-name in each pair is the most-referenced filename across follow-up migrations + runbooks. Each renamed file's header carries an `IN-PLACE EDIT (SCA-282, …)` block documenting the rationale, mirroring the SCA-280 / SCA-139 pattern.

## See also

- `CLAUDE.md` §"Schema truth" — column-type retcons, CHECK constraints worth knowing.
- `CLAUDE.md` §"Immutable-migration policy" — the rules for when a file may be edited (security-fix exception only).
- `docs/runbooks/supabase-migration-reconciliation.md` — what to do when local and prod migration tables drift.
