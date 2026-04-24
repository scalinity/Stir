-- Stir — cost anomaly Sentry alerting
-- Step 8 Phase 5.
--
-- Design (ADR 0023, spec §13 alerts):
--   - `stir_ops_cost_anomaly_scan()` inserts rows into cost_anomalies.
--   - A second pg_cron job (every 1 min) reads rows with alerted_at IS NULL
--     and POSTs a Sentry store event per row via pg_net, then stamps
--     alerted_at = now().
--   - Keeping the scan and the dispatch in separate ticks avoids coupling
--     their failure modes: a Sentry outage must not block anomaly detection,
--     and a scan regression must not silently kill alerts.
--
-- Sentry store endpoint (no auth beyond the DSN's public key):
--   POST https://oXXXX.ingest.sentry.io/api/<project-id>/store/
--        ?sentry_key=<public-key>
--        &sentry_version=7
--
-- Body: a Sentry "event" payload. Minimal shape:
--   { "event_id", "timestamp", "level", "message", "tags", "extra" }
--
-- Runtime config: the Sentry DSN is NOT a Postgres secret; we store it in
-- `public.app_settings(key TEXT PK, value TEXT)` (service-role only). Null
-- DSN → dispatch function skips quietly so local dev doesn't page ghosts.

-- ---------------------------------------------------------------------------
-- app_settings: minimal key/value for runtime config that doesn't belong in
-- feature_flags (feature_flags.payload_json is user/feature-facing; this is
-- backend-infra-facing).
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS app_settings (
  key        TEXT PRIMARY KEY,
  value      TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE app_settings ENABLE ROW LEVEL SECURITY;
-- Intentionally no policies → service-role only.
COMMENT ON TABLE app_settings IS 'Backend runtime config (service-role only). Keys: SENTRY_DSN, etc.';

-- Seed placeholder rows so the dispatch function handles NULL cleanly.
INSERT INTO app_settings (key, value) VALUES ('SENTRY_DSN', NULL)
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- stir_ops_cost_anomaly_alert_dispatch — reads unsent anomalies, POSTs to
-- Sentry via pg_net, marks alerted_at. Runs every 1 min.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.stir_ops_cost_anomaly_alert_dispatch()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_dsn        TEXT;
  v_parsed     TEXT[];
  v_public_key TEXT;
  v_host       TEXT;
  v_project_id TEXT;
  v_store_url  TEXT;
  v_row        RECORD;
  v_body       JSONB;
  v_sent       INTEGER := 0;
BEGIN
  SELECT value INTO v_dsn FROM app_settings WHERE key = 'SENTRY_DSN';
  IF v_dsn IS NULL OR length(v_dsn) = 0 THEN
    -- No DSN configured (local dev, or pre-beta) — skip quietly.
    RETURN 0;
  END IF;

  -- Parse DSN: https://<public_key>@<host>/<project_id>
  v_parsed := regexp_match(v_dsn, '^https?://([^@]+)@([^/]+)/(.+)$');
  IF v_parsed IS NULL OR array_length(v_parsed, 1) <> 3 THEN
    RAISE WARNING 'SENTRY_DSN malformed: %', v_dsn;
    RETURN 0;
  END IF;
  v_public_key := v_parsed[1];
  v_host       := v_parsed[2];
  v_project_id := v_parsed[3];
  v_store_url  := format('https://%s/api/%s/store/?sentry_key=%s&sentry_version=7',
                         v_host, v_project_id, v_public_key);

  -- Iterate unsent anomalies, up to 50 per tick to bound pg_net queue depth.
  FOR v_row IN (
    SELECT id, canonical_user_key_hash, anomaly_type, severity, details_json, detected_at
    FROM cost_anomalies
    WHERE alerted_at IS NULL
    ORDER BY detected_at ASC
    LIMIT 50
  ) LOOP
    v_body := jsonb_build_object(
      'event_id',  replace(v_row.id::text, '-', ''),
      'timestamp', v_row.detected_at,
      'level',     CASE v_row.severity WHEN 'critical' THEN 'error' ELSE 'warning' END,
      'logger',    'stir.cost_anomaly',
      'message',   format('cost anomaly: %s (severity=%s) for user %s',
                          v_row.anomaly_type, v_row.severity, v_row.canonical_user_key_hash),
      'tags',      jsonb_build_object(
                     'anomaly_type', v_row.anomaly_type::text,
                     'severity',     v_row.severity::text,
                     'user_hash',    v_row.canonical_user_key_hash),
      'extra',     v_row.details_json
    );

    PERFORM net.http_post(
      url := v_store_url,
      body := v_body,
      headers := jsonb_build_object('content-type', 'application/json'),
      timeout_milliseconds := 3000
    );

    UPDATE cost_anomalies SET alerted_at = now() WHERE id = v_row.id;
    v_sent := v_sent + 1;
  END LOOP;

  RETURN v_sent;
END $$;

REVOKE ALL ON FUNCTION public.stir_ops_cost_anomaly_alert_dispatch() FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.stir_ops_cost_anomaly_alert_dispatch() TO service_role;

COMMENT ON FUNCTION public.stir_ops_cost_anomaly_alert_dispatch() IS
  'Cron-invoked every 1 min. Reads cost_anomalies rows with alerted_at IS NULL (up to 50 per tick), posts one Sentry store event per row via pg_net, stamps alerted_at. Decoupled from scan so Sentry outages do not block detection.';

-- ---------------------------------------------------------------------------
-- pg_cron: 1-min alert dispatch (supplements the 15-min scan from P1.6).
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'stir-cost-anomaly-alert-dispatch') THEN
    PERFORM cron.unschedule('stir-cost-anomaly-alert-dispatch');
  END IF;

  PERFORM cron.schedule(
    'stir-cost-anomaly-alert-dispatch',
    '* * * * *',  -- every 1 min
    $job$
      SELECT public.stir_ops_cost_anomaly_alert_dispatch();
    $job$
  );
END
$$;
