-- Stir operational schema — cost_anomalies
-- Step 8: detector output table. Populated every 15 min by pg_cron-scheduled
-- `stir_ops_cost_anomaly_scan()` (migration 20260423000009_ops_admin_rpcs.sql).
--
-- Detection thresholds (spec §13 alerts + Daniel's step 8 prompt):
--   daily_spend_2x              Premium > $3/day OR Pro > $8/day (2x expected)
--   daily_spend_hard_cap        ANY user > $10/day (irrespective of tier)
--   voice_session_tokens_over_cap  session trace_id cumulative tokens > 50K
--   runaway_session             single session > 10 min AND > 20 turns
--
-- Each detection type dedupes within a 24h window (NOT EXISTS clause in
-- the scan RPC) so a single misbehaving user doesn't fill the table with
-- duplicate rows. An admin resolving (`resolved_at=now()`) opens the
-- door to a fresh alert the next tick.
--
-- Severity mapping:
--   warn      alert-worthy, page during business hours
--   critical  page immediately; ops console highlights red
--
-- Sentry integration: the scan RPC uses pg_net to POST a store event to
-- Sentry's DSN when it inserts a new row. `alerted_at` is stamped on
-- successful POST so a retry tick doesn't double-alert.
--
-- RLS: is_admin() SELECT + UPDATE. Service role INSERT/DELETE.

CREATE TYPE cost_anomaly_type AS ENUM (
  'daily_spend_2x',
  'daily_spend_hard_cap',
  'voice_session_tokens_over_cap',
  'runaway_session'
);

CREATE TYPE cost_anomaly_severity AS ENUM ('warn', 'critical');

CREATE TABLE IF NOT EXISTS cost_anomalies (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  canonical_user_key_hash  TEXT NOT NULL,
  anomaly_type             cost_anomaly_type NOT NULL,
  severity                 cost_anomaly_severity NOT NULL,
  -- Detection snapshot: varies by anomaly_type.
  --   daily_spend_2x / daily_spend_hard_cap:
  --     { tier, spend_24h_usd, call_count, top_features: [...] }
  --   voice_session_tokens_over_cap:
  --     { trace_id, cumulative_prompt_tokens, cumulative_response_tokens, turn_count }
  --   runaway_session:
  --     { trace_id, duration_ms, turn_count }
  details_json             JSONB NOT NULL,
  detected_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  alerted_at               TIMESTAMPTZ,
  resolved_at              TIMESTAMPTZ,
  resolved_by              UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  resolution_notes         TEXT
);

-- Open-anomalies feed: primary ops console page query.
CREATE INDEX IF NOT EXISTS idx_cost_anomalies_open
  ON cost_anomalies(detected_at DESC)
  WHERE resolved_at IS NULL;

-- Dedup key for the 24h-NOT-EXISTS clause in the scan RPC.
CREATE INDEX IF NOT EXISTS idx_cost_anomalies_dedup
  ON cost_anomalies(canonical_user_key_hash, anomaly_type, detected_at DESC);

-- Sentry-alert dispatch queue: find rows that haven't been alerted yet.
-- (Separate from `open` because a resolved row might not have been
-- alerted; we still want to emit the event before marking resolved.)
CREATE INDEX IF NOT EXISTS idx_cost_anomalies_unalerted
  ON cost_anomalies(detected_at ASC)
  WHERE alerted_at IS NULL;

-- Severity-ordered browse for "show me critical first".
CREATE INDEX IF NOT EXISTS idx_cost_anomalies_severity
  ON cost_anomalies(severity, detected_at DESC);

ALTER TABLE cost_anomalies ENABLE ROW LEVEL SECURITY;

CREATE POLICY cost_anomalies_admin_select ON cost_anomalies
  FOR SELECT TO authenticated
  USING (public.is_admin());

CREATE POLICY cost_anomalies_admin_update ON cost_anomalies
  FOR UPDATE TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- No INSERT / DELETE for authenticated. Scan RPC and manual cleanup use
-- service-role.

COMMENT ON TABLE  cost_anomalies                          IS 'Cost anomaly detections. Populated by stir_ops_cost_anomaly_scan() every 15 min. Alerts via pg_net → Sentry.';
COMMENT ON COLUMN cost_anomalies.canonical_user_key_hash  IS 'SHA-256(canonical_user_key, 16-char truncation). Matches the hashing convention used by ops_flagged_outputs + PostHog distinct_id.';
COMMENT ON COLUMN cost_anomalies.anomaly_type             IS 'daily_spend_2x | daily_spend_hard_cap | voice_session_tokens_over_cap | runaway_session';
COMMENT ON COLUMN cost_anomalies.severity                 IS 'warn (email/Slack) | critical (page oncall)';
COMMENT ON COLUMN cost_anomalies.details_json             IS 'Snapshot of metrics at detection time. Shape varies by anomaly_type. See migration comment.';
COMMENT ON COLUMN cost_anomalies.detected_at              IS 'When the scan RPC inserted this row.';
COMMENT ON COLUMN cost_anomalies.alerted_at               IS 'When Sentry ingest confirmed the store event. NULL until the scan RPC''s pg_net POST succeeds.';
COMMENT ON COLUMN cost_anomalies.resolved_at              IS 'When an admin marked this row reviewed. Dedup window re-opens after resolve.';
