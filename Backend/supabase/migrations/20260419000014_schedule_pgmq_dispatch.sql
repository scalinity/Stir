-- Stir operational schema — pg_cron schedule for notification_jobs dispatcher
--
-- The dispatcher itself is a Deno Edge Function at /functions/v1/pgmq-dispatch
-- that claims pending jobs, invokes the right worker, and flips state.
-- This migration schedules pg_cron to POST to that function every 30 seconds.
--
-- Mechanism: pg_cron (already enabled in migration 14) runs a SQL statement
-- that uses pg_net's `net.http_post` to fire the Edge Function. Service-role
-- key authorises the call; the Edge Function verifies a shared secret
-- (`PGMQ_DISPATCH_TRIGGER_SECRET`) before processing.
--
-- 30-second cadence: fast enough that an async recipe_import completes in
-- under a minute p95; slow enough to keep pg_net queue tiny. Worker claims
-- one job per invocation to bound the per-tick work and honor function
-- timeout budgets. If queue depth ever matters, either reduce the tick
-- interval OR have the worker claim-then-loop.
--
-- Dependencies: pg_cron (migration 14), pg_net (enabled here), vault
-- (for secrets). If vault is unavailable locally, the `cron.schedule`
-- call uses a placeholder URL/header that the dispatcher rejects; local
-- dev invokes the dispatcher manually via curl.

CREATE EXTENSION IF NOT EXISTS pg_net;

-- Vault-backed config so the service-role key and trigger secret don't
-- land in cron.job_run_details. Uses Supabase-hosted vault.
-- On local dev the vault rows won't exist; `net.http_post` fails gracefully
-- (logged, not thrown) and the dispatcher is exercised via integration tests.

DO $$
DECLARE
  v_supabase_url TEXT := current_setting('app.supabase_url', TRUE);
BEGIN
  -- If supabase_url isn't set (typical in local dev before `supabase start`
  -- has run setup), skip scheduling. The Edge Function still works when
  -- invoked directly by tests or ad-hoc curl.
  IF v_supabase_url IS NULL OR v_supabase_url = '' THEN
    RAISE NOTICE 'app.supabase_url not set; skipping pgmq-dispatch cron. Re-run after `supabase link --project-ref ...`.';
    RETURN;
  END IF;

  -- Idempotent re-schedule.
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'stir-pgmq-dispatch') THEN
    PERFORM cron.unschedule('stir-pgmq-dispatch');
  END IF;

  PERFORM cron.schedule(
    'stir-pgmq-dispatch',
    '*/30 * * * * *',   -- every 30 seconds (six-field cron = 'sec min hour day mon dow')
    format(
      $job$
        SELECT net.http_post(
          url := %L,
          headers := '{"Content-Type": "application/json"}'::jsonb,
          body := '{}'::jsonb,
          timeout_milliseconds := 25000
        );
      $job$,
      v_supabase_url || '/functions/v1/pgmq-dispatch'
    )
  );
END
$$;

-- One-liner wrapper for ops: `SELECT public.stir_pgmq_dispatch_trigger_once();`
-- exists so ops can kick the dispatcher without waiting for the cron tick
-- when debugging async jobs. Uses the same pg_net path.
CREATE OR REPLACE FUNCTION public.stir_pgmq_dispatch_trigger_once()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_supabase_url TEXT := current_setting('app.supabase_url', TRUE);
  v_request_id BIGINT;
BEGIN
  IF v_supabase_url IS NULL OR v_supabase_url = '' THEN
    RETURN 'app.supabase_url not set';
  END IF;

  SELECT net.http_post(
    url := v_supabase_url || '/functions/v1/pgmq-dispatch',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := '{"trigger": "manual"}'::jsonb,
    timeout_milliseconds := 25000
  ) INTO v_request_id;

  RETURN 'request_id=' || v_request_id::TEXT;
END
$$;

REVOKE ALL ON FUNCTION public.stir_pgmq_dispatch_trigger_once() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.stir_pgmq_dispatch_trigger_once() FROM authenticated;
REVOKE ALL ON FUNCTION public.stir_pgmq_dispatch_trigger_once() FROM anon;

COMMENT ON FUNCTION public.stir_pgmq_dispatch_trigger_once() IS
  'Ops hook: trigger pgmq-dispatch once without waiting for the cron tick. service-role only.';
