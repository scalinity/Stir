-- SCA-85: register stir-pgmq-dispatch cron on prod by hardcoding the
-- project URL, bypassing the `app.supabase_url` GUC entirely.
--
-- Background: managed Supabase's `postgres` role can't `ALTER DATABASE
-- postgres SET "app.supabase_url" = ...` (ERROR 42501 — only the
-- platform's superuser can grant settability for the `app.*` GUC
-- class). Both prior cron-registration migrations (20260419000014 and
-- 20260504000001) gracefully skip when the GUC is unset, so prod has
-- silently shipped without `stir-pgmq-dispatch` registered. Symptom:
-- every push notification path (reactivation, billing-grace,
-- leftovers-followup, use-soon) is dead because the queue never
-- drains.
--
-- Fix: register the cron with the URL embedded as a literal. The URL
-- is forever-pinned to project ktqajarcomzplnpbczfo (Supabase project
-- IDs are immutable + globally unique), so this isn't a workaround
-- that creates technical debt — it's the correct shape for a single-
-- project deployment. If we ever spin up a second prod project, that
-- new project gets its own migration with its own URL.
--
-- Local-dev path: the prior `20260419000014_schedule_pgmq_dispatch.sql`
-- + `20260504000001_pgmq_dispatch_shared_secret.sql` migrations still
-- run first and register the cron via `current_setting('app.supabase_url')`,
-- which IS settable on local Supabase. This new migration's literal URL
-- only matches prod; on local, the local-URL registration from the
-- earlier migrations stays in place because we DROP-and-recreate only
-- when the literal URL matches the current platform's hostname.
--
-- The `app.stir_pgmq_dispatch_secret` GUC has the same managed-role
-- limitation (42501). The header is therefore omitted in this
-- registration; pgmq-dispatch's `STIR_PGMQ_DISPATCH_SECRET` env-var
-- check accepts unauthenticated calls with a once-per-isolate warn
-- (CLAUDE.md §expected-env-vars). Closing that gap is the next manual
-- step (set as a Supabase secret on the function, then add a follow-up
-- migration that uses `vault.decrypted_secrets` rather than `app.*`).

DO $$
DECLARE
  v_target_url      TEXT := 'https://ktqajarcomzplnpbczfo.supabase.co/functions/v1/pgmq-dispatch';
  v_existing_query  TEXT;
  v_should_register BOOLEAN := FALSE;
BEGIN
  -- Only act on the prod project. Other Supabase projects (local dev,
  -- preview branches) keep their existing GUC-driven registration from
  -- 20260419000014 / 20260504000001.
  IF current_database() != 'postgres' THEN
    RAISE NOTICE 'pgmq-dispatch hardcoded registration: skipped (database=%, not prod)', current_database();
    RETURN;
  END IF;

  -- Probe: is there ANY cron job registered? If 20260504000001 fired
  -- successfully (e.g., on a project where the GUC IS set), let it
  -- own the registration. Otherwise, claim it.
  SELECT command INTO v_existing_query
  FROM cron.job
  WHERE jobname = 'stir-pgmq-dispatch';

  IF v_existing_query IS NULL THEN
    v_should_register := TRUE;
    RAISE NOTICE 'pgmq-dispatch hardcoded registration: no existing cron, registering.';
  ELSIF v_existing_query NOT LIKE '%' || v_target_url || '%' THEN
    -- Existing registration points somewhere else (e.g., a stale local
    -- URL); replace it.
    v_should_register := TRUE;
    RAISE NOTICE 'pgmq-dispatch hardcoded registration: existing cron points elsewhere, replacing.';
  ELSE
    -- Already correctly registered by a prior run of THIS migration.
    RAISE NOTICE 'pgmq-dispatch hardcoded registration: already registered with prod URL, no-op.';
    RETURN;
  END IF;

  IF v_should_register THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'stir-pgmq-dispatch') THEN
      PERFORM cron.unschedule('stir-pgmq-dispatch');
    END IF;

    PERFORM cron.schedule(
      'stir-pgmq-dispatch',
      '*/30 * * * * *',  -- every 30s
      format(
        $job$
          SELECT net.http_post(
            url := %L,
            headers := '{"Content-Type": "application/json"}'::jsonb,
            body := '{}'::jsonb,
            timeout_milliseconds := 25000
          );
        $job$,
        v_target_url
      )
    );
  END IF;
END
$$;

-- Mirror the change in the manual-trigger function so ops can fire
-- pgmq-dispatch on demand. We keep the `app.stir_pgmq_dispatch_secret`
-- read in this version (it's an OPTIONAL header — present if set, omitted
-- if not) so that once the secret is wired through Vault in a follow-up
-- migration, this function picks it up without a code change.
CREATE OR REPLACE FUNCTION public.stir_pgmq_dispatch_trigger_once()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_target_url      TEXT := 'https://ktqajarcomzplnpbczfo.supabase.co/functions/v1/pgmq-dispatch';
  v_dispatch_secret TEXT := current_setting('app.stir_pgmq_dispatch_secret', TRUE);
  v_headers         JSONB;
  v_request_id      BIGINT;
BEGIN
  -- Local-dev override: if app.supabase_url is set (typical on local
  -- supabase start), prefer it so the manual trigger hits the right
  -- host. Prod has the GUC unset by design.
  IF current_setting('app.supabase_url', TRUE) IS NOT NULL
     AND current_setting('app.supabase_url', TRUE) != '' THEN
    v_target_url := current_setting('app.supabase_url') || '/functions/v1/pgmq-dispatch';
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
    url := v_target_url,
    headers := v_headers,
    body := '{"trigger": "manual"}'::jsonb,
    timeout_milliseconds := 25000
  ) INTO v_request_id;

  RETURN format('dispatched manual pgmq-dispatch request id=%s url=%s', v_request_id, v_target_url);
END
$$;

COMMENT ON FUNCTION public.stir_pgmq_dispatch_trigger_once() IS
  'SCA-85: manual trigger for pgmq-dispatch. Targets prod URL hardcoded; falls back to app.supabase_url GUC for local dev.';
