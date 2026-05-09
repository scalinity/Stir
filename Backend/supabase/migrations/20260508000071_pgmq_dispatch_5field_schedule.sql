-- IN-PLACE EDIT (SCA-282, correctness-blocks-fresh-init exception per
-- CLAUDE.md §Schema truth):
--   This file was originally named `20260508000007_pgmq_dispatch_5field_schedule.sql`
--   and shared the `20260508000007` version prefix with
--   `20260508000007_stir_claim_deletion_requests.sql`. Same fresh-init
--   PK collision as SCA-282's 000006 fix — see that migration's header
--   for the full rationale. `_stir_claim_deletion_requests` keeps the
--   canonical timestamp (load-bearing for users-deletion-fulfill RPC
--   and referenced by 20260508000012's clamp-notice migration);
--   `_pgmq_dispatch_5field_schedule` rebases to `_000071_...`.
--
-- pgmq-dispatch cron schedule: switch to 5-field every-minute.
--
-- Discovered post-SCA-157 deploy: managed Supabase has
-- `cron.use_background_workers = off`, which means pg_cron's launcher
-- only fires once per minute regardless of what the schedule string
-- requests. Sub-minute precision (`*/30 * * * * *`) silently degrades
-- to a worse-than-1-minute cadence — the prior cron was firing at
-- 30-minute intervals (HH:00, HH:30) per net._http_response history,
-- not the intended 30-second cadence.
--
-- 6-field syntax also stopped firing entirely after the SCA-157
-- re-registration (jobid 12, 0 runs over 40+ minutes while sibling
-- jobids 8/9 fired every minute).
--
-- `cron.use_background_workers = on` requires `ALTER SYSTEM SET`,
-- which is blocked on managed Supabase (same 42501 class as the
-- `app.*` GUC). So 1-minute is the floor.
--
-- Switch to `* * * * *` (every minute):
--   * Strict improvement over the prior effective 30-minute cadence.
--   * Push notifications drain within 60s — well below user-
--     perceptible threshold for SCA-77 billing_grace + reactivation +
--     leftovers-followup + use-soon + recipe-import-async.
--   * Reliable: pg_cron's launcher fires every minute by design.
--
-- This migration redefines `_register_pgmq_dispatch_cron()` with the
-- new schedule + calls it once. All future calls to the function
-- (rotation procedure) will use 1-minute cadence too.

CREATE OR REPLACE FUNCTION public._register_pgmq_dispatch_cron()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_target_url      TEXT := 'https://ktqajarcomzplnpbczfo.supabase.co/functions/v1/pgmq-dispatch';
  v_dispatch_secret TEXT;
  v_headers         JSONB;
  v_command         TEXT;
  v_existing        TEXT;
  -- 1-minute cadence (5-field). Sub-minute precision needs
  -- cron.use_background_workers=on, which managed Supabase blocks.
  v_schedule        TEXT := '* * * * *';
BEGIN
  IF current_database() != 'postgres' THEN
    RETURN format('skipped: database=%s, not prod', current_database());
  END IF;

  SELECT decrypted_secret
  INTO v_dispatch_secret
  FROM vault.decrypted_secrets
  WHERE name = 'stir_pgmq_dispatch_secret';

  IF v_dispatch_secret IS NULL OR v_dispatch_secret = '' THEN
    v_headers := '{"Content-Type": "application/json"}'::jsonb;
    RAISE NOTICE 'pgmq-dispatch: vault entry stir_pgmq_dispatch_secret missing — registering with bare header (fail-open).';
  ELSE
    v_headers := jsonb_build_object(
      'Content-Type',       'application/json',
      'X-Stir-Cron-Secret', v_dispatch_secret
    );
  END IF;

  v_command := format(
    $job$
          SELECT net.http_post(
            url := %L,
            headers := %L::jsonb,
            body := '{}'::jsonb,
            timeout_milliseconds := 25000
          );
        $job$,
    v_target_url,
    v_headers::text
  );

  -- Idempotent: if both schedule and command already match, no-op.
  -- Compare via cron.job's schedule + command columns.
  SELECT command INTO v_existing
  FROM cron.job
  WHERE jobname = 'stir-pgmq-dispatch'
    AND schedule = v_schedule;

  IF v_existing IS NOT NULL AND v_existing = v_command THEN
    RETURN 'no-op: cron already registered with current schedule + secret state';
  END IF;

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'stir-pgmq-dispatch') THEN
    PERFORM cron.unschedule('stir-pgmq-dispatch');
  END IF;

  PERFORM cron.schedule(
    'stir-pgmq-dispatch',
    v_schedule,
    v_command
  );

  IF v_dispatch_secret IS NULL THEN
    RETURN 'registered: cron with bare header @ 1-minute cadence (Vault entry missing)';
  ELSE
    RETURN 'registered: cron with X-Stir-Cron-Secret header @ 1-minute cadence';
  END IF;
END
$$;

COMMENT ON FUNCTION public._register_pgmq_dispatch_cron() IS
  'SCA-157: idempotent cron re-registration. Reads stir_pgmq_dispatch_secret from vault.decrypted_secrets. 1-minute schedule (managed Supabase has cron.use_background_workers=off; sub-minute is unavailable). Run after vault.create_secret/update_secret to pick up new values.';

DO $$
DECLARE
  v_result TEXT;
BEGIN
  v_result := public._register_pgmq_dispatch_cron();
  RAISE NOTICE 'pgmq-dispatch register result: %', v_result;
END
$$;
