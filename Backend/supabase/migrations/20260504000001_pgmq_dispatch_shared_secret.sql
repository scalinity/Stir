-- pgmq-dispatch shared-secret gate (SA2-Medium fix, 2026-05-04)
--
-- Migration 20260419000014 promised "the Edge Function verifies a shared
-- secret (PGMQ_DISPATCH_TRIGGER_SECRET) before processing", but the gate
-- was never implemented — pgmq-dispatch accepted unauthenticated invocations
-- on a public Supabase URL, making it a cost-amplification / DoS surface
-- if the URL ever leaked (Sentry, CI logs, screenshots).
--
-- This migration:
--   1. Reads `app.stir_pgmq_dispatch_secret` from server config (set via
--      `ALTER DATABASE ... SET app.stir_pgmq_dispatch_secret = '...'`, or
--      the deploy runbook's vault-backed pattern).
--   2. Re-schedules the cron job with `X-Stir-Cron-Secret: <value>` header.
--   3. Updates `stir_pgmq_dispatch_trigger_once()` to send the same header.
--
-- The Edge Function (Backend/supabase/functions/pgmq-dispatch/index.ts) reads
-- `STIR_PGMQ_DISPATCH_SECRET` and rejects mismatched headers with AUTH-01.
-- If the env var is unset on the function side (local dev), the function
-- accepts all calls and logs a once-per-isolate warn — same defense-in-depth
-- pattern as LOG_IP_SALT.
--
-- Production deploy procedure:
--   1. Generate a 32-byte random secret (e.g. `openssl rand -hex 32`).
--   2. `supabase secrets set STIR_PGMQ_DISPATCH_SECRET=<value>` (function side).
--   3. `ALTER DATABASE postgres SET app.stir_pgmq_dispatch_secret = '<value>';`
--      (Postgres side — use the same value).
--   4. `supabase db push` (this migration re-reads on apply).
--   5. `supabase functions deploy pgmq-dispatch`.
--
-- The two sides MUST hold the same value; either side is rotated by:
--   (a) updating Postgres setting, (b) rotating supabase secret, (c) supabase
--   functions redeploy. Brief mismatch window during step (b)→(c) results in
--   AUTH-01 + queue lag (recovers automatically once the deploy lands); no
--   data loss because notification_jobs rows stay 'pending'.

DO $$
DECLARE
  v_supabase_url    TEXT := current_setting('app.supabase_url', TRUE);
  v_dispatch_secret TEXT := current_setting('app.stir_pgmq_dispatch_secret', TRUE);
  v_headers         JSONB;
BEGIN
  IF v_supabase_url IS NULL OR v_supabase_url = '' THEN
    RAISE NOTICE 'app.supabase_url not set; skipping pgmq-dispatch reschedule.';
    RETURN;
  END IF;

  -- Build headers. If the secret isn't set, send only Content-Type — the
  -- function will accept (with a warn log) until the secret is configured.
  IF v_dispatch_secret IS NULL OR v_dispatch_secret = '' THEN
    v_headers := '{"Content-Type": "application/json"}'::jsonb;
    RAISE NOTICE 'app.stir_pgmq_dispatch_secret not set; pgmq-dispatch cron will run without authenticated header. Set the secret to close the gap.';
  ELSE
    v_headers := jsonb_build_object(
      'Content-Type',         'application/json',
      'X-Stir-Cron-Secret',   v_dispatch_secret
    );
  END IF;

  -- Idempotent re-schedule.
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'stir-pgmq-dispatch') THEN
    PERFORM cron.unschedule('stir-pgmq-dispatch');
  END IF;

  PERFORM cron.schedule(
    'stir-pgmq-dispatch',
    '*/30 * * * * *',
    format(
      $job$
        SELECT net.http_post(
          url := %L,
          headers := %L::jsonb,
          body := '{}'::jsonb,
          timeout_milliseconds := 25000
        );
      $job$,
      v_supabase_url || '/functions/v1/pgmq-dispatch',
      v_headers::text
    )
  );
END
$$;

-- Replace the ops trigger function so its manual call also carries the header.
CREATE OR REPLACE FUNCTION public.stir_pgmq_dispatch_trigger_once()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_supabase_url    TEXT := current_setting('app.supabase_url', TRUE);
  v_dispatch_secret TEXT := current_setting('app.stir_pgmq_dispatch_secret', TRUE);
  v_headers         JSONB;
  v_request_id      BIGINT;
BEGIN
  IF v_supabase_url IS NULL OR v_supabase_url = '' THEN
    RETURN 'app.supabase_url not set';
  END IF;

  IF v_dispatch_secret IS NULL OR v_dispatch_secret = '' THEN
    v_headers := '{"Content-Type": "application/json"}'::jsonb;
  ELSE
    v_headers := jsonb_build_object(
      'Content-Type',         'application/json',
      'X-Stir-Cron-Secret',   v_dispatch_secret
    );
  END IF;

  SELECT net.http_post(
    url := v_supabase_url || '/functions/v1/pgmq-dispatch',
    headers := v_headers,
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
  'Ops hook: trigger pgmq-dispatch once without waiting for the cron tick. Sends X-Stir-Cron-Secret if configured. service-role only.';
