# Supabase migration drift reconciliation

When `cd Backend && supabase migration list --project-ref ktqajarcomzplnpbczfo`
shows rows where Local and Remote disagree, the local file index has
drifted from the remote `supabase_migrations.schema_migrations` table.
This runbook is the recipe for safe reconciliation.

## When this happens

- A migration was applied directly via the Supabase dashboard SQL editor
  (skipping the CLI)
- A migration was applied via a fork/branch that used a different
  filename timestamp
- The CLI auto-renamed a file during `supabase db push` (it sometimes
  rewrites the timestamp to microsecond precision); the local file
  retained the older name
- A migration's body ran via some other mechanism (psql, Edge Function
  RPC) without an entry being recorded in the tracking table

## Reconciliation procedure

### Step 1 — diagnose

```
cd Backend
supabase link --project-ref ktqajarcomzplnpbczfo
supabase migration list
```

Read both columns. Each row is one of three cases:

| Case | Meaning | Action category |
|---|---|---|
| Local + Remote both filled, equal | Already synced | skip |
| Local filled, Remote empty | Local file present; not tracked on remote | verify whether body actually ran |
| Local empty, Remote filled | Remote tracker has an entry with no local file | verify whether body actually ran |

### Step 2 — verify actual deployment status (the critical step)

For every row where Local and Remote disagree, query the database to
verify whether the migration's effect is actually present. Don't trust
the tracker alone — repair must reflect reality.

Read the migration's SQL body and pick the most distinctive
DDL/DML it ran, then verify that effect on prod via
`mcp__supabase__execute_sql`. Examples:

| Migration kind | Verification query |
|---|---|
| Creates a table | `SELECT to_regclass('public.<name>') IS NOT NULL` |
| Creates a function | `SELECT count(*) FROM pg_proc WHERE proname = '<fn>'` |
| Updates a function body | `SELECT pg_get_functiondef(oid) LIKE '%<sentinel>%' FROM pg_proc WHERE proname = '<fn>'` |
| Schedules a cron | `SELECT count(*) FROM cron.job WHERE jobname = '<job>'` |
| Sets a Postgres setting | `SELECT current_setting('<key>', true) IS NOT NULL` |
| Seeds a row | `SELECT count(*) FROM <table> WHERE <unique key> = <value>` |

Two outcomes per row:

- **Effect present** on remote → tracker drift only; needs `repair`
- **Effect absent** on remote → genuine pending migration; needs `db push`

### Step 3 — repair drift

For local-only rows where the effect is **already present** on remote:

```
supabase migration repair --status applied <id1> <id2> ...
```

For remote-only rows that are duplicates of local files (CLI-renamed,
or applied twice with different timestamps):

```
supabase migration repair --status reverted <id1> <id2> ...
```

(`reverted` only removes the tracker row — it does NOT roll back DDL.
Use it when the effect is already accounted for under a different
tracker ID.)

### Step 4 — confirm alignment

```
supabase migration list
```

After repair, every row's Local and Remote columns must be either both
filled or both empty (the latter only for genuinely-pending migrations).

### Step 5 — push remaining pending

```
supabase db push
# If the CLI complains about gaps (a pending migration predates the
# most-recent applied), re-run with --include-all:
supabase db push --include-all
```

### Step 6 — verify the new effects landed

For every newly-applied migration, run the same verification query
from step 2.

### Step 7 — advisor sweep

```
mcp__supabase__get_advisors type=security
mcp__supabase__get_advisors type=performance
```

Document any WARN+ that wasn't there before the push as a follow-up.
INFO-level findings on `rls_enabled_no_policy` for `app_users` /
`feature_flags` / `prompt_versions` are by-design deny-all per CLAUDE.md
and can be ignored.

## Audit trail

Every reconciliation event should append a section to this file with:
- date
- the rows repaired (status applied vs reverted, with verification queries)
- the rows pushed
- advisor findings before/after

### 2026-05-07 — initial drift reconciliation (SCA-84)

Triggered by SCA-63 prod deploy attempt finding 5 local-only and 2
remote-only entries in `migration list`.

**Verification of local-only effects on remote (via `execute_sql`):**

| Local ID | Effect verified | Status |
|---|---|---|
| `20260424000007` | `pg_get_functiondef(oid) LIKE '%canonical_user_key_hash%'` on `stir_ops_cost_anomaly_alert_dispatch` returned true | applied |
| `20260504000001` | `current_setting('app.stir_pgmq_dispatch_secret', true)` returned NULL | NOT applied |
| `20260506000001` | Duplicate content of remote `20260506195507`; verified via name match | applied (under different timestamp) |
| `20260506230001` | Duplicate content of remote `20260506233049`; verified via name match | applied (under different timestamp) |
| `20260507000001` | `SELECT 1 FROM prompt_versions WHERE feature_key='dinner_solve' AND version='2.1.0'` returned a row | applied |
| `20260508000001` (SCA-63) | `SELECT 1 FROM cron.job WHERE jobname='stir-cleanup-ai-request-log'` returned 0 rows | NOT applied |

**Repair commands run:**

```
supabase migration repair --status reverted 20260506195507 20260506233049
supabase migration repair --status applied 20260424000007 20260506000001 20260506230001 20260507000001
supabase db push --include-all
# applied 20260504000001 + 20260508000001
```

**Post-push verification:**

- `stir-cleanup-ai-request-log` cron exists with schedule `23 * * * *`, active=true ✓
- `stir_pgmq_dispatch_trigger_once` function updated to read `app.stir_pgmq_dispatch_secret` and emit `X-Stir-Cron-Secret` header when set ✓
- `20260504000001` migration NOTICE'd that `app.supabase_url` Postgres setting is unset, so the `cron.schedule('stir-pgmq-dispatch', ...)` block early-returned. Cron `stir-pgmq-dispatch` is consequently absent from `cron.job`. **Separate ops gap from SCA-84 — see follow-up section below.**

**Advisor sweep — no new WARN/ERROR findings introduced by these migrations.** All flagged rules are pre-existing INFO-level (by-design deny-all RLS) or pre-existing WARN-level (pg_net schema, stir_waitlist permissive insert, SECURITY DEFINER admin funcs, leaked-password-protection auth setting).

### Follow-up: `app.supabase_url` Postgres setting unset on prod

Discovered during SCA-84 verification. The pgmq-dispatch cron registration in `20260419000014_schedule_pgmq_dispatch.sql` AND the secret-gate update in `20260504000001_pgmq_dispatch_shared_secret.sql` both early-return when `app.supabase_url` Postgres setting is null. Result: `stir-pgmq-dispatch` cron has never been registered on prod.

Impact:
- `notification_jobs` rows enqueued by `stir_ops_reactivation_enqueue`, recipe-import async, future SCA-77 billing grace push will not fire — they sit in `pending` state forever
- Reactivation campaigns (step 8) effectively dead on prod
- Any push notification path is gated on this

Fix:
```
ALTER DATABASE postgres SET app.supabase_url = 'https://ktqajarcomzplnpbczfo.supabase.co';
-- Then re-apply the latest cron-scheduling migration to register the cron.
-- Cleanest: a new migration that conditionally registers the cron with the
-- secret-gated invocation, OR a one-shot `SELECT cron.schedule(...)` call.
```

This is **out of scope for SCA-84** (which was just "reconcile the drift"). Filed as a follow-up — see SCA-84 Linear comment for the spawn ticket.
