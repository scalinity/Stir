-- SCA-88 follow-forward: deletion_request stale-state Sentry alerts.
--
-- The original fulfillment schedule shipped in 20260508000006. That
-- migration has already been applied remotely, so the alerting acceptance
-- criterion lands as a new forward migration.
--
-- Alerts:
--   * state='approved' older than 24h
--   * state='failed' older than 12h
--
-- Uses the same app_settings.SENTRY_DSN store-event pattern as cost
-- anomaly alerting. Dispatch markers live under
-- external_refs_json.alerts so each row alerts once per stale state.

CREATE OR REPLACE FUNCTION public.stir_deletion_request_sla_alert_dispatch()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_dsn          TEXT;
  v_parsed       TEXT[];
  v_public_key   TEXT;
  v_host         TEXT;
  v_project_id   TEXT;
  v_store_url    TEXT;
  v_row          RECORD;
  v_body         JSONB;
  v_request_id   BIGINT;
  v_alert_key    TEXT;
  v_sent         INTEGER := 0;
BEGIN
  SELECT value INTO v_dsn FROM app_settings WHERE key = 'SENTRY_DSN';
  IF v_dsn IS NULL OR length(v_dsn) = 0 THEN
    RETURN 0;
  END IF;

  v_parsed := regexp_match(v_dsn, '^https?://([^@]+)@([^/]+)/(.+)$');
  IF v_parsed IS NULL OR array_length(v_parsed, 1) <> 3 THEN
    RAISE WARNING 'SENTRY_DSN malformed (length=%, prefix=%)',
                  length(v_dsn), left(v_dsn, 20);
    RETURN 0;
  END IF;

  v_public_key := v_parsed[1];
  v_host       := v_parsed[2];
  v_project_id := v_parsed[3];
  v_store_url  := format('https://%s/api/%s/store/?sentry_key=%s&sentry_version=7',
                         v_host, v_project_id, v_public_key);

  FOR v_row IN (
    SELECT id, canonical_user_key_hash, state, requested_at, approved_at,
           started_at, updated_at, failure_reason, external_refs_json
      FROM deletion_requests
     WHERE (
            state = 'approved'
        AND approved_at < now() - interval '24 hours'
        AND external_refs_json #>> '{alerts,approved_stale,dispatched_at}' IS NULL
     )
        OR (
            state = 'failed'
        AND updated_at < now() - interval '12 hours'
        AND external_refs_json #>> '{alerts,failed_stale,dispatched_at}' IS NULL
     )
     ORDER BY requested_at ASC
     LIMIT 50
  ) LOOP
    v_alert_key := CASE
      WHEN v_row.state = 'approved' THEN 'approved_stale'
      ELSE 'failed_stale'
    END;

    v_body := jsonb_build_object(
      'event_id',  replace(v_row.id::text, '-', ''),
      'timestamp', now(),
      'level',     'error',
      'logger',    'stir.deletion_request',
      'message',   format('deletion request %s stale in state %s for user %s',
                          v_row.id, v_row.state, v_row.canonical_user_key_hash),
      'tags',      jsonb_build_object(
                     'state', v_row.state::text,
                     'alert_key', v_alert_key,
                     'user_hash', v_row.canonical_user_key_hash),
      'extra',     jsonb_build_object(
                     'deletion_request_id', v_row.id,
                     'requested_at', v_row.requested_at,
                     'approved_at', v_row.approved_at,
                     'started_at', v_row.started_at,
                     'failure_reason', v_row.failure_reason)
    );

    v_request_id := net.http_post(
      url := v_store_url,
      body := v_body,
      headers := jsonb_build_object('content-type', 'application/json'),
      timeout_milliseconds := 3000
    );

    UPDATE deletion_requests
       SET external_refs_json = jsonb_set(
             COALESCE(external_refs_json, '{}'::jsonb),
             '{alerts}',
             COALESCE(external_refs_json -> 'alerts', '{}'::jsonb) ||
               jsonb_build_object(
                 v_alert_key,
                 jsonb_build_object(
                   'dispatched_at', now(),
                   'sentry_request_id', v_request_id
                 )
               ),
             true
           )
     WHERE id = v_row.id;

    v_sent := v_sent + 1;
  END LOOP;

  RETURN v_sent;
END
$$;

REVOKE ALL ON FUNCTION public.stir_deletion_request_sla_alert_dispatch() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.stir_deletion_request_sla_alert_dispatch() TO service_role;

COMMENT ON FUNCTION public.stir_deletion_request_sla_alert_dispatch() IS
  'SCA-88: Sentry store-event dispatch for stale deletion_requests rows. Alerts approved >24h and failed >12h once per state via external_refs_json.alerts markers.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE NOTICE 'pg_cron not installed; skipping stir-deletion-request-sla-alert schedule.';
    RETURN;
  END IF;

  PERFORM cron.unschedule('stir-deletion-request-sla-alert')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'stir-deletion-request-sla-alert');

  PERFORM cron.schedule(
    'stir-deletion-request-sla-alert',
    '*/15 * * * *',
    $job$
      SELECT public.stir_deletion_request_sla_alert_dispatch();
    $job$
  );
END
$$;
