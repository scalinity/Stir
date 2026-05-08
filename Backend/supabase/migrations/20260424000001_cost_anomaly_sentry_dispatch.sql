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

-- SCA-139 / telemetry audit G12 (W25): function body stubbed in-place.
-- The original implementation here emitted the full SENTRY_DSN (including
-- the public key, which is auth-bearing on Sentry's store ingest endpoint)
-- to the Postgres log on the malformed-parse path:
--   RAISE WARNING 'SENTRY_DSN malformed: %', v_dsn
-- Superseded by `20260424000004_cost_anomaly_two_phase_dispatch.sql` which:
--   1. Adds two-phase dispatched_at / sentry_request_id / confirmed_at /
--      confirm_attempts columns to cost_anomalies (the active execution
--      shape the new dispatch function relies on)
--   2. Truncates the DSN log to `length + left(v_dsn, 20)` so the public
--      key never reaches the function log
-- This stub stays in place so re-applying `000001` standalone produces no
-- log emission at all (vs re-introducing the pre-W25 leak). The pg_cron
-- schedule below registers `stir-cost-anomaly-alert-dispatch` to call this
-- function every minute; until `000004`'s CREATE OR REPLACE runs, the
-- function is a no-op returning 0. Migrations apply sequentially within a
-- single `supabase db reset`, so cron does not fire between `000001` and
-- `000004` — the active body is in place before the first scheduled tick.
-- Immutable-migration policy exception: security fix is the only allowed
-- in-place edit class (see CLAUDE.md, ticket SCA-139 acceptance criteria).
CREATE OR REPLACE FUNCTION public.stir_ops_cost_anomaly_alert_dispatch()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  RETURN 0;
END $$;

REVOKE ALL ON FUNCTION public.stir_ops_cost_anomaly_alert_dispatch() FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.stir_ops_cost_anomaly_alert_dispatch() TO service_role;

COMMENT ON FUNCTION public.stir_ops_cost_anomaly_alert_dispatch() IS
  'STUB — superseded by 20260424000004. Original body emitted full SENTRY_DSN to log on malformed parse (telemetry audit G12 / SCA-139). Stripped in-place under immutable-migration security-fix exception. Active definition lives in 20260424000004_cost_anomaly_two_phase_dispatch.sql.';

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
