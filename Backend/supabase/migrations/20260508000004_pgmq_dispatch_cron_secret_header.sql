-- SCA-85 follow-up: cron must include `X-Stir-Cron-Secret` when the
-- `app.stir_pgmq_dispatch_secret` GUC is set, OR the moment SCA-157
-- sets `STIR_PGMQ_DISPATCH_SECRET` on the function side, every cron
-- POST will return AUTH-01 401 and the entire push pipeline goes dark
-- (reactivation, billing-grace, leftovers-followup, use-soon, recipe-
-- import-async). Caught in the multi-agent code review (CA2-01 / SA2-H1)
-- as the highest-priority operational item.
--
-- The previous migration (20260508000003) registered the cron with a
-- bare `Content-Type: application/json` header. The manual-trigger
-- function (`stir_pgmq_dispatch_trigger_once`) DID conditionally read
-- the secret GUC and add the header — creating an asymmetry where the
-- manual path was authenticated while the cron path was not.
--
-- Fix: re-register the cron with the same conditional-header logic the
-- manual function uses. Read `app.stir_pgmq_dispatch_secret` at cron-
-- registration time; if set, bake `X-Stir-Cron-Secret` into the cron
-- command literal. If unset (the current prod state), keep the bare
-- header so the fail-open path still drains the queue.
--
-- Also tighten the manual function (`stir_pgmq_dispatch_trigger_once`):
-- the previous version preferentially read `app.supabase_url` GUC
-- BEFORE falling back to the hardcoded prod URL. On a hypothetical
-- preview branch with the GUC set, the cron would target prod while
-- the manual trigger would target the preview function — silent split-
-- brain. Mirror the cron's `current_database()='postgres'` guard so
-- the manual path on prod also uses the literal URL exclusively.
--
-- Re-apply safety: the same idempotent probe shape from 20260508000003
-- (compare existing cron command to target URL+headers, no-op when
-- already correct, replace when stale).

DO $$
DECLARE
  v_target_url      TEXT := 'https://ktqajarcomzplnpbczfo.supabase.co/functions/v1/pgmq-dispatch';
  v_dispatch_secret TEXT := current_setting('app.stir_pgmq_dispatch_secret', TRUE);
  v_headers         JSONB;
  v_headers_text    TEXT;
  v_existing_query  TEXT;
  v_should_register BOOLEAN := FALSE;
  v_expected_command TEXT;
BEGIN
  -- Prod-only registration. Local dev / preview keep their GUC-driven
  -- registration from 20260419000014 / 20260504000001.
  IF current_database() != 'postgres' THEN
    RAISE NOTICE 'pgmq-dispatch cron secret: skipped (database=%, not prod)', current_database();
    RETURN;
  END IF;

  -- Build the headers JSONB the cron will send. If the secret is unset,
  -- we keep the bare Content-Type header — the function-side gate is
  -- fail-open in that case (matches the design while SCA-157 is pending).
  IF v_dispatch_secret IS NULL OR v_dispatch_secret = '' THEN
    v_headers := '{"Content-Type": "application/json"}'::jsonb;
    RAISE NOTICE 'pgmq-dispatch cron secret: GUC unset, registering with bare Content-Type header (fail-open path).';
  ELSE
    v_headers := jsonb_build_object(
      'Content-Type',       'application/json',
      'X-Stir-Cron-Secret', v_dispatch_secret
    );
    RAISE NOTICE 'pgmq-dispatch cron secret: GUC set, registering with X-Stir-Cron-Secret header.';
  END IF;
  v_headers_text := v_headers::text;

  -- Build the expected cron command body so the idempotent probe can
  -- compare against the existing registration's `command` column.
  v_expected_command := format(
    $job$
          SELECT net.http_post(
            url := %L,
            headers := %L::jsonb,
            body := '{}'::jsonb,
            timeout_milliseconds := 25000
          );
        $job$,
    v_target_url,
    v_headers_text
  );

  SELECT command INTO v_existing_query
  FROM cron.job
  WHERE jobname = 'stir-pgmq-dispatch';

  IF v_existing_query IS NULL THEN
    v_should_register := TRUE;
    RAISE NOTICE 'pgmq-dispatch cron secret: no existing cron, registering.';
  ELSIF v_existing_query NOT LIKE '%' || v_target_url || '%' THEN
    v_should_register := TRUE;
    RAISE NOTICE 'pgmq-dispatch cron secret: existing cron points elsewhere, replacing.';
  ELSIF (v_dispatch_secret IS NOT NULL AND v_dispatch_secret != ''
         AND v_existing_query NOT LIKE '%X-Stir-Cron-Secret%') THEN
    -- Secret is now set, but the existing cron registration was made
    -- when it was unset — re-register so the header lands.
    v_should_register := TRUE;
    RAISE NOTICE 'pgmq-dispatch cron secret: GUC newly set, re-registering with header.';
  ELSIF (v_dispatch_secret IS NULL OR v_dispatch_secret = '')
        AND v_existing_query LIKE '%X-Stir-Cron-Secret%' THEN
    -- Secret was unset (rotation rollback?), but cron still carries
    -- the old header value — re-register without the header so the
    -- fail-open path works.
    v_should_register := TRUE;
    RAISE NOTICE 'pgmq-dispatch cron secret: GUC newly unset, re-registering without header.';
  ELSE
    RAISE NOTICE 'pgmq-dispatch cron secret: already correctly registered, no-op.';
    RETURN;
  END IF;

  IF v_should_register THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'stir-pgmq-dispatch') THEN
      PERFORM cron.unschedule('stir-pgmq-dispatch');
    END IF;

    PERFORM cron.schedule(
      'stir-pgmq-dispatch',
      '*/30 * * * * *',
      v_expected_command
    );
  END IF;
END
$$;

-- Update the manual-trigger function to drop the asymmetric local-dev
-- GUC override on prod. The previous version preferentially read
-- `app.supabase_url` if set; on prod we want the hardcoded URL only,
-- and the local-dev path retains the GUC override via the existing
-- `20260504000001` registration (which this migration doesn't touch).
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
  -- Local-dev override: only honor the `app.supabase_url` GUC on
  -- non-prod databases. On prod the GUC is unset by design (SCA-85),
  -- and we want the literal URL to win exclusively to avoid split-
  -- brain with the cron registration above.
  IF current_database() != 'postgres'
     AND current_setting('app.supabase_url', TRUE) IS NOT NULL
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

  -- Reset session GUCs that could have been SET LOCAL'd to redirect
  -- the request — defensive against a future grant relaxation that
  -- would make this function callable by non-DBA roles. SA1-M2 / CWE-918.
  RESET app.supabase_url;

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
  'SCA-85 + SCA-85 follow-up: manual trigger for pgmq-dispatch. Prod uses the literal URL (no GUC override); local dev honors `app.supabase_url`. Reads `app.stir_pgmq_dispatch_secret` GUC; conditionally adds X-Stir-Cron-Secret header to match the cron registration. RESETs app.supabase_url at entry to defend against session-scope GUC override (CWE-918).';
