-- ADR 0027 + canonical-properties.md (Phase D) — Sentry tag standardization
-- on cost-anomaly dispatch.
--
-- Context: the canonical telemetry schema (ADR 0027) pinned
-- `canonical_user_key_hash` as the single name for the SHA-256 user
-- identity hash. The cost-anomaly Sentry path (introduced in
-- 20260424000004) attached the hash as `tags.user_hash` — a deviation
-- the Phase A audit (G2 + G9) flagged for rename. This migration:
--
-- 1. Renames `tags.user_hash` → `tags.canonical_user_key_hash` in the
--    Sentry event body emitted by stir_ops_cost_anomaly_alert_dispatch.
-- 2. Adds `tags.actor_id = 'system:cron'` per the §3 system-actor
--    convention. Distinguishes scheduler-driven events from
--    admin-driven events on cross-system dashboards.
-- 3. Does NOT add `tags.request_id` — cron-invoked surfaces have no
--    HTTP request scope; per §7.1 the row primary key (`event_id` =
--    `cost_anomalies.id`) is the surface-specific cross-system join key.
--
-- Function body is otherwise identical to migration 20260424000004's
-- definition: same two-phase dispatch, same W15 batched UPDATE, same
-- W25 truncated DSN log redaction. Only the v_body.tags subobject
-- changes.
--
-- Backward-compat note: rows already dispatched to Sentry under the
-- old `tags.user_hash` name remain in Sentry's index under that tag.
-- Dashboards keying on user identity for cost anomalies must query
-- BOTH `tags.user_hash` AND `tags.canonical_user_key_hash` for the
-- transition window (24h post-deploy is enough — Sentry retention on
-- tag indexes is bounded). After 24h, every active anomaly will have
-- been dispatched under the new name.

BEGIN;

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
    -- Sentry event body. Tags conform to canonical-properties.md
    -- (Phase D — ADR 0027): canonical_user_key_hash as the user
    -- identity (NOT the legacy user_hash); actor_id='system:cron'
    -- per §3 system-actor convention; request_id intentionally
    -- omitted per §7.1 cron carve-out (event_id = cost_anomalies.id
    -- is the surface-specific cross-system join key).
    v_body := jsonb_build_object(
      'event_id',  replace(v_row.id::text, '-', ''),
      'timestamp', v_row.detected_at,
      'level',     CASE v_row.severity WHEN 'critical' THEN 'error' ELSE 'warning' END,
      'logger',    'stir.cost_anomaly',
      'message',   format('cost anomaly: %s (severity=%s) for user %s',
                          v_row.anomaly_type, v_row.severity, v_row.canonical_user_key_hash),
      'tags',      jsonb_build_object(
                     'anomaly_type',             v_row.anomaly_type::text,
                     'severity',                 v_row.severity::text,
                     'canonical_user_key_hash',  v_row.canonical_user_key_hash,
                     'actor_id',                 'system:cron'),
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

COMMENT ON FUNCTION public.stir_ops_cost_anomaly_alert_dispatch() IS
  'Phase 1 of two-phase Sentry dispatch. Reads unsent anomalies (up to 50/tick), POSTs via pg_net, captures request_id. Paired with stir_ops_cost_anomaly_alert_confirm. Tags conform to ADR 0027 / canonical-properties.md (Phase D, 2026-04-24): canonical_user_key_hash + actor_id=system:cron; request_id omitted per §7.1 cron carve-out (event_id is the join key).';

COMMIT;
