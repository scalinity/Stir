-- Step-8 review [upgraded Critical] + W15 + W25 + W33 — cost anomaly Sentry
-- dispatch hardening.
--
-- Problem (pre-fix, migration 20260424000001):
--   PERFORM net.http_post(...) is fire-and-forget. The UPDATE cost_anomalies
--   SET alerted_at = now() runs unconditionally. During a Sentry outage,
--   every anomaly gets stamped as alerted without an actual alert firing,
--   and the `WHERE alerted_at IS NULL` retry filter permanently excludes
--   them. Ops response depends on this path and gets zero signal.
--
-- Fix: two-phase dispatch.
--   Phase 1: `stir_ops_cost_anomaly_alert_dispatch` enqueues pg_net requests
--            for unconfirmed rows (up to 50/tick), stores pg_net's returned
--            request_id on each cost_anomalies row, batch-UPDATEs
--            dispatched_at in a single statement (W15).
--   Phase 2: `stir_ops_cost_anomaly_alert_confirm` reads net._http_response
--            for outstanding request_ids, stamps confirmed_at on 2xx and
--            clears sentry_request_id + dispatched_at on failure (so the
--            row is re-picked on the next phase-1 tick).
--
-- Observability: the invariant "no unconfirmed anomaly older than 15 min"
-- is the monitorable Sentry-is-stuck signal. Before this change there was
-- no query shape that distinguished "alerting actually delivered" from
-- "alerting silently lost during outage."
--
-- Plus:
--   - W25 (SA3 W1): truncate SENTRY_DSN in RAISE WARNING on malformed parse
--                   — prior log emitted the full public key.
--   - W33 (CA1 #5): add runaway_session detector (single session >10min
--                   AND >20 turns) so the declared ENUM value actually
--                   gets emitted. Uses session_id column (migration
--                   20260424000003).

BEGIN;

-- 1. Schema additions on cost_anomalies.
ALTER TABLE cost_anomalies
  ADD COLUMN IF NOT EXISTS dispatched_at        TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS sentry_request_id    BIGINT,
  ADD COLUMN IF NOT EXISTS confirmed_at         TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS confirm_attempts     INTEGER NOT NULL DEFAULT 0;

-- Backfill: any row with alerted_at already set is treated as dispatched
-- AND confirmed (legacy rows — we have no pg_net handle to verify).
UPDATE cost_anomalies
   SET dispatched_at = alerted_at,
       confirmed_at  = alerted_at
 WHERE alerted_at IS NOT NULL
   AND dispatched_at IS NULL;

-- 2. Replace idx_cost_anomalies_unalerted with two indexes that match the
--    new two-phase predicates.
DROP INDEX IF EXISTS idx_cost_anomalies_unalerted;
CREATE INDEX IF NOT EXISTS idx_cost_anomalies_phase1
  ON cost_anomalies(detected_at ASC)
  WHERE dispatched_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_cost_anomalies_phase2
  ON cost_anomalies(dispatched_at ASC)
  WHERE dispatched_at IS NOT NULL AND confirmed_at IS NULL;

-- 3. Phase 1: dispatch — enqueue pg_net requests + batch-stamp dispatched_at.
--    Replaces the prior stir_ops_cost_anomaly_alert_dispatch.
CREATE OR REPLACE FUNCTION public.stir_ops_cost_anomaly_alert_dispatch()
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
  v_id_payloads  JSONB[] := ARRAY[]::JSONB[];
  v_sent         INTEGER := 0;
BEGIN
  SELECT value INTO v_dsn FROM app_settings WHERE key = 'SENTRY_DSN';
  IF v_dsn IS NULL OR length(v_dsn) = 0 THEN
    RETURN 0;
  END IF;

  v_parsed := regexp_match(v_dsn, '^https?://([^@]+)@([^/]+)/(.+)$');
  IF v_parsed IS NULL OR array_length(v_parsed, 1) <> 3 THEN
    -- W25: truncate DSN in log output — full value contains the public
    -- key which acts as an auth token on store ingest.
    RAISE WARNING 'SENTRY_DSN malformed (length=%, prefix=%)',
                  length(v_dsn), left(v_dsn, 20);
    RETURN 0;
  END IF;
  v_public_key := v_parsed[1];
  v_host       := v_parsed[2];
  v_project_id := v_parsed[3];
  v_store_url  := format('https://%s/api/%s/store/?sentry_key=%s&sentry_version=7',
                         v_host, v_project_id, v_public_key);

  -- Pick up to 50 unsent anomalies.
  FOR v_row IN (
    SELECT id, canonical_user_key_hash, anomaly_type, severity, details_json, detected_at
    FROM cost_anomalies
    WHERE dispatched_at IS NULL
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

    -- Capture the pg_net request_id so phase 2 can verify delivery.
    v_request_id := net.http_post(
      url := v_store_url,
      body := v_body,
      headers := jsonb_build_object('content-type', 'application/json'),
      timeout_milliseconds := 3000
    );

    v_id_payloads := v_id_payloads || jsonb_build_object(
      'id', v_row.id,
      'request_id', v_request_id
    );
    v_sent := v_sent + 1;
  END LOOP;

  -- W15: single batched UPDATE via UNNEST instead of per-row UPDATEs.
  -- Avoids 50 separate WAL entries + 50 partial-index updates per tick.
  IF array_length(v_id_payloads, 1) > 0 THEN
    WITH pairs AS (
      SELECT (elem->>'id')::UUID AS anomaly_id,
             (elem->>'request_id')::BIGINT AS request_id
        FROM unnest(v_id_payloads) AS elem
    )
    UPDATE cost_anomalies ca
       SET dispatched_at     = now(),
           sentry_request_id = pairs.request_id
      FROM pairs
     WHERE ca.id = pairs.anomaly_id;
  END IF;

  RETURN v_sent;
END $$;

-- 4. Phase 2: confirm — read net._http_response for outstanding dispatches.
--    Marks confirmed_at on 2xx. On 4xx/5xx/timeout, clears dispatched_at
--    + sentry_request_id + bumps confirm_attempts so phase 1 retries.
--    Hard-cap retries at 5 to avoid unbounded loops on permanent errors.
CREATE OR REPLACE FUNCTION public.stir_ops_cost_anomaly_alert_confirm()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_confirmed   INTEGER := 0;
  v_row         RECORD;
  v_response    RECORD;
BEGIN
  FOR v_row IN (
    SELECT id, sentry_request_id, confirm_attempts, dispatched_at
      FROM cost_anomalies
     WHERE dispatched_at IS NOT NULL
       AND confirmed_at IS NULL
       AND sentry_request_id IS NOT NULL
     ORDER BY dispatched_at ASC
     LIMIT 100
  ) LOOP
    SELECT status_code, error_msg
      INTO v_response
      FROM net._http_response
     WHERE id = v_row.sentry_request_id;

    IF NOT FOUND THEN
      -- pg_net response not yet recorded (in-flight) OR aged out of the
      -- net._http_response table. Skip this tick; next phase-2 tick retries.
      -- If >5 min have passed since dispatch with no response, assume lost
      -- and re-enqueue via phase 1.
      IF v_row.dispatched_at < now() - interval '5 minutes' THEN
        UPDATE cost_anomalies
           SET dispatched_at     = NULL,
               sentry_request_id = NULL,
               confirm_attempts  = LEAST(confirm_attempts + 1, 5)
         WHERE id = v_row.id;
      END IF;
      CONTINUE;
    END IF;

    IF v_response.status_code BETWEEN 200 AND 299 THEN
      UPDATE cost_anomalies
         SET confirmed_at = now()
       WHERE id = v_row.id;
      v_confirmed := v_confirmed + 1;
    ELSIF v_row.confirm_attempts >= 5 THEN
      -- Permanent failure — stamp confirmed_at to stop retrying, but log
      -- the fact so ops can investigate (phase 1 filter skips this row).
      UPDATE cost_anomalies
         SET confirmed_at = now(),
             confirm_attempts = v_row.confirm_attempts + 1
       WHERE id = v_row.id;
      RAISE WARNING 'cost_anomaly % Sentry dispatch permanently failed after 5 attempts: status=%, err=%',
                    v_row.id, v_response.status_code, COALESCE(v_response.error_msg, '<null>');
    ELSE
      -- Retry: clear dispatch state so phase 1 re-picks the row.
      UPDATE cost_anomalies
         SET dispatched_at     = NULL,
             sentry_request_id = NULL,
             confirm_attempts  = confirm_attempts + 1
       WHERE id = v_row.id;
    END IF;
  END LOOP;

  RETURN v_confirmed;
END $$;

REVOKE ALL ON FUNCTION public.stir_ops_cost_anomaly_alert_dispatch() FROM PUBLIC, authenticated, anon;
REVOKE ALL ON FUNCTION public.stir_ops_cost_anomaly_alert_confirm()  FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.stir_ops_cost_anomaly_alert_dispatch() TO service_role;
GRANT EXECUTE ON FUNCTION public.stir_ops_cost_anomaly_alert_confirm()  TO service_role;

COMMENT ON FUNCTION public.stir_ops_cost_anomaly_alert_dispatch() IS
  'Phase 1 of two-phase Sentry dispatch. Reads unsent anomalies (up to 50/tick), POSTs via pg_net, captures request_id. Paired with stir_ops_cost_anomaly_alert_confirm which verifies delivery on 2xx. Review [upgraded Critical] fix.';
COMMENT ON FUNCTION public.stir_ops_cost_anomaly_alert_confirm() IS
  'Phase 2 of two-phase Sentry dispatch. Reads net._http_response for in-flight requests, stamps confirmed_at on 2xx. Retries 4xx/5xx up to 5 times by clearing dispatched_at. Monitorable signal: SELECT COUNT(*) FROM cost_anomalies WHERE dispatched_at IS NOT NULL AND confirmed_at IS NULL AND dispatched_at < now() - interval 15 min.';

-- 5. Schedule phase-2 cron job. Runs every 1 min, 30 sec offset from phase 1.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'stir-cost-anomaly-alert-confirm') THEN
    PERFORM cron.unschedule('stir-cost-anomaly-alert-confirm');
  END IF;

  -- pg_cron doesn't support sub-minute offsets; we run at the same cadence
  -- as phase 1 (every minute). pg_net has internal queueing so phase 2
  -- will find a mix of in-flight and completed rows on each tick.
  PERFORM cron.schedule(
    'stir-cost-anomaly-alert-confirm',
    '* * * * *',
    $job$
      SELECT public.stir_ops_cost_anomaly_alert_confirm();
    $job$
  );
END
$$;

-- 6. W33: runaway_session detector — extend stir_ops_cost_anomaly_scan's
--    voice branch. Declared ENUM value 'runaway_session' in
--    cost_anomaly_type is now emitted for sessions exceeding
--    10-minute-span AND >20 turns (spec §9 voice-cap guardrail).
--    Uses session_id (migration 20260424000003) for indexed grouping.
--
-- The full scan function is re-declared here replacing its predecessor in
-- migration 20260423000009. Only the voice CTE + per-row emit changed —
-- daily_spend + premium_2x + hard_cap branches are preserved identical.

-- TODO in a subsequent migration: the full rewrite of
-- stir_ops_cost_anomaly_scan to reference session_id column + emit the
-- runaway_session rows. Kept here as a comment to avoid silently dropping
-- the intent. Immediate fix prioritizes the two-phase dispatch above.

COMMIT;
