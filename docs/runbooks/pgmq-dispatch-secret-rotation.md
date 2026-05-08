# Runbook: `STIR_PGMQ_DISPATCH_SECRET` rotation

**Owner:** Daniel. **Trigger:** suspected secret leak, quarterly hygiene rotation, pre-public-launch hardening.

## Why the secret exists

`pgmq-dispatch` runs on a public Supabase Edge Function URL. Migration `20260419000014_schedule_pgmq_dispatch.sql` originally promised "the Edge Function verifies a shared secret before processing", but the gate landed empty — the function accepted unauthenticated invocations until `20260504000001_pgmq_dispatch_shared_secret.sql` closed it (SA2-Medium fix, 2026-05-04).

The gate enforces:

- pg_cron sets `X-Stir-Cron-Secret: <value>` on the every-minute dispatch tick.
- `stir_pgmq_dispatch_trigger_once()` (the manual ops kick) sets the same header.
- The function (`Backend/supabase/functions/pgmq-dispatch/index.ts`) does a constant-time compare against `STIR_PGMQ_DISPATCH_SECRET` and rejects mismatches with `AUTH-01`.

Threat model: an attacker who learns the Edge Function URL but NOT the secret cannot drain `notification_jobs` (cost-amplification / DoS), cannot trigger arbitrary APNs sends, and cannot exhaust the queue by spamming the endpoint. Once the URL is public (beta + later), the secret is the only thing standing between cron-only access and "anyone with the URL."

**Two-sided invariant.** The Edge Function reads `Deno.env.get('STIR_PGMQ_DISPATCH_SECRET')` once at module load. Postgres reads `current_setting('app.stir_pgmq_dispatch_secret', TRUE)` at migration apply time and bakes the value into the cron job's request body. Both sides MUST hold the same value or every cron tick produces `AUTH-01` and `notification_jobs` rows pile up in `pending`.

> **Vault note (SCA-85 / future work):** `app.stir_pgmq_dispatch_secret` is a Postgres GUC. On managed Supabase the GUC has the same `42501 must be superuser` limitation that bit `app.supabase_url` during the 2026-05-08 reconciliation. Long-term, the GUC should be replaced by a Vault-backed read (per SCA-85's resolution path). Until that ships, the rotation procedure below requires DDL-level access to set the GUC; if you don't have it, contact Supabase support to apply the `ALTER DATABASE` for you.

## Cadence

- **Quarterly** (operational hygiene). Calendar-anchored to the start of Q1/Q2/Q3/Q4; rotate within the first business week.
- **Immediately** on any of: suspected leak (Sentry attachment, screenshot, public PR diff), staff turnover with secret access, or a Sentry-attributed `AUTH-01 X-Stir-Cron-Secret` rate that suggests probing.

## Pre-rotation checklist

- [ ] You have shell access to `supabase` CLI linked to project `ktqajarcomzplnpbczfo`.
- [ ] You have Postgres SQL access to prod (Supabase SQL Editor or `psql` via the connection string).
- [ ] You can copy/paste a 64-char hex secret into both surfaces in the same session — DO NOT save it to disk between steps.
- [ ] No active `notification_jobs` deploy or backfill in flight (rotation introduces a < 60s window where the cron tick may 401; rows stay in `pending` and recover on the next tick after redeploy, so this is informational, not blocking).

## Rotation procedure

### Step 1 — Generate the new secret

```bash
openssl rand -hex 32
```

Copy the 64-char hex output. Keep it in a paste buffer for the next two steps; do NOT echo it into shell history (`set +o history` if needed).

### Step 2 — Set on Postgres side first (DDL)

```sql
ALTER DATABASE postgres SET app.stir_pgmq_dispatch_secret = '<new-hex>';
```

This re-applies on every fresh connection. Confirm via:

```sql
SELECT length(current_setting('app.stir_pgmq_dispatch_secret', TRUE)) AS len;
-- → 64
```

### Step 3 — Re-apply the dispatch migration to rebuild the cron with the new header

The migration is idempotent (`SELECT cron.unschedule(...)` then `SELECT cron.schedule(...)`); re-applying it picks up the new GUC and rebuilds the cron's request body.

```bash
supabase db push --project-ref ktqajarcomzplnpbczfo
```

If you don't want to push the entire migration tree, run the migration's body manually in the SQL Editor (the `DO $$ ... $$` block in `20260504000001_pgmq_dispatch_shared_secret.sql`).

Verify the cron picked up the new secret:

```sql
SELECT jobname, schedule, command
  FROM cron.job
 WHERE jobname = 'stir-pgmq-dispatch';
-- the `command` column should contain the new secret in the headers JSONB
```

> **Brief mismatch window.** Between Step 3 (cron sends new secret) and Step 4 (function still expects old secret), every cron tick produces `AUTH-01`. The window is bounded by how fast Step 4 lands (target: < 60s). Rows accumulate in `notification_jobs.pending`; they drain automatically after Step 4 + the next tick.

### Step 4 — Set on Edge Function side and redeploy

```bash
supabase secrets set --project-ref ktqajarcomzplnpbczfo STIR_PGMQ_DISPATCH_SECRET=<new-hex>
supabase functions deploy pgmq-dispatch --project-ref ktqajarcomzplnpbczfo
```

### Step 5 — Smoke test

Manually trigger one dispatch to confirm both sides agree on the new secret:

```sql
SELECT public.stir_pgmq_dispatch_trigger_once();
-- expected: TEXT containing 'request_id=...' (200 OK from the function)
```

Tail the function log for the next 60s and confirm:

- No `[pgmq-dispatch] AUTH-01` lines
- No `STIR_PGMQ_DISPATCH_SECRET unset` warning
- Normal `dispatched=N` summary lines on every tick

Drain any backlog that piled up during the mismatch window:

```sql
SELECT count(*) FROM notification_jobs WHERE status = 'pending';
-- expected: 0 within ~2 cron ticks (~2 min)
```

### Step 6 — Log the rotation

Append to `docs/runbooks/secret-rotation-log.md` (create if missing):

```
2026-MM-DD | STIR_PGMQ_DISPATCH_SECRET rotated | Daniel | quarterly / suspected-leak / pre-launch
```

## If the secret leaks

1. Run Steps 1–5 immediately. The brief AUTH-01 window is acceptable; the alternative (leaving a leaked secret in place) is worse.
2. If the leak source is recoverable (Sentry attachment, GitHub gist), redact / delete it AFTER rotation, not before — rotating first invalidates the leaked value.
3. Audit `cron.job_run_details` for the past 24h for unusual invocations (look for entries from outside the cron schedule, or with non-200 status codes that bracket the leak window).

## If `STIR_PGMQ_DISPATCH_SECRET` is unset on the function side

The function falls back to accepting all calls and emits a once-per-isolate stderr warning:

```
[pgmq-dispatch] STIR_PGMQ_DISPATCH_SECRET unset — accepting unauthenticated invocations. Set the secret before exposing this function publicly.
```

This is the defense-in-depth fallback for local dev (`supabase functions serve` without `.env`). On prod, treat the warning as a P1 alert — set the secret per Step 4 immediately. Dashboards can query the function log for the literal "STIR_PGMQ_DISPATCH_SECRET unset" string and alert on any non-zero count.

## If `app.stir_pgmq_dispatch_secret` is unset on the Postgres side

The migration's `IF v_dispatch_secret IS NULL OR v_dispatch_secret = '' THEN ...` branch builds the cron request WITHOUT the `X-Stir-Cron-Secret` header (sending only `Content-Type`). Combined with the function-side fallback (above), this means cron will work — but the gate is fully open.

Symptom: function logs show `STIR_PGMQ_DISPATCH_SECRET unset` warnings AND cron is producing 200s on every tick. This is the worst of both worlds (gate open, no observability of the misconfig propagating to the cron side either). Set the GUC per Step 2 and re-apply the migration per Step 3.

## Non-goals

- This runbook does NOT address the cron job's pg_net retry semantics — those are handled by pg_cron's built-in retry, separately governed.
- This runbook does NOT replace the Vault migration path (SCA-85 follow-up). When Vault is wired, the GUC step will collapse into a Vault read; the Edge Function side rotation will remain the same.

## References

- `Backend/supabase/migrations/20260504000001_pgmq_dispatch_shared_secret.sql` — gate landing
- `Backend/supabase/functions/pgmq-dispatch/index.ts` — function-side verification
- `Backend/supabase/migrations/20260419000014_schedule_pgmq_dispatch.sql` — original cron registration + `stir_pgmq_dispatch_trigger_once()` ops helper
- SCA-85 — `app.supabase_url` reconciliation; same managed-Supabase GUC class as `app.stir_pgmq_dispatch_secret`
- CLAUDE.md §expected-env-vars — points back at this runbook
