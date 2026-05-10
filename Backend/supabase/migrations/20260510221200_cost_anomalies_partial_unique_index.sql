-- SCA-303 (/review-5 W9 + S16 + S7) — close TOCTOU race in cost-anomaly
-- dedup by promoting the dedup-via-NOT-EXISTS subquery to a partial UNIQUE
-- index, then rewrite stir_ops_cost_anomaly_scan to use ON CONFLICT
-- DO NOTHING. Two ticks of the cron racing (or manual ops + cron firing
-- simultaneously) used to both observe "no open row" and both INSERT,
-- producing duplicate critical anomalies and double Sentry alerts. The
-- partial UNIQUE indexes make duplicates impossible at the storage layer
-- regardless of how many concurrent invocations run.
--
-- Two indexes, because cost_anomalies carries two distinct dedup grains:
--   * Daily-spend anomalies dedup on (user, anomaly_type) — one open row
--     per user per type at a time. The unresolved-window concept lives at
--     the proc level (24h cooldown), not the index — the index just
--     enforces "exactly one open row at a time".
--   * Per-session voice anomalies dedup on (user, anomaly_type, session_id)
--     because two distinct sessions can both be in flight and each should
--     get its own open row. session_id lives inside details_json as a
--     JSONB key; the index uses an expression on details_json->>'session_id'.
--
-- Forward-only supersession of the dedup logic in
-- 20260509144834_cost_anomaly_scan_session_id_rewrite.sql — that migration
-- stays immutable per CLAUDE.md immutable-migration policy; this dated
-- migration holds the canonical definition going forward.

-- ---------------------------------------------------------------------------
-- Partial UNIQUE indexes — storage-level dedup guarantee.
-- ---------------------------------------------------------------------------
-- IF NOT EXISTS guards future repeat applies. The WHERE clauses match the
-- proc's dedup semantics exactly: unresolved rows of the matching type
-- are unique within their grain.

CREATE UNIQUE INDEX IF NOT EXISTS uq_cost_anomalies_open
  ON cost_anomalies (canonical_user_key_hash, anomaly_type)
  WHERE resolved_at IS NULL
    AND anomaly_type IN ('daily_spend_2x', 'daily_spend_hard_cap');

COMMENT ON INDEX uq_cost_anomalies_open IS
  'SCA-303: One open daily-spend row per (user, anomaly_type). Closes TOCTOU race in stir_ops_cost_anomaly_scan (W9).';

CREATE UNIQUE INDEX IF NOT EXISTS uq_cost_anomalies_open_session
  ON cost_anomalies (canonical_user_key_hash, anomaly_type, (details_json->>'session_id'))
  WHERE resolved_at IS NULL
    AND anomaly_type IN ('voice_session_tokens_over_cap', 'runaway_session');

COMMENT ON INDEX uq_cost_anomalies_open_session IS
  'SCA-303: One open per-session voice row per (user, anomaly_type, session_id). Closes TOCTOU race; also serves as the index that the dedup ON CONFLICT clause matches.';

-- ---------------------------------------------------------------------------
-- stir_ops_cost_anomaly_scan — rewrite to ON CONFLICT DO NOTHING.
-- ---------------------------------------------------------------------------
-- Behavior unchanged from 20260509144834: same daily-spend thresholds,
-- same voice token-cap branch (>50K), same runaway_session branch
-- (>20 turns AND >10min span). Only the dedup mechanism changes:
-- NOT EXISTS subquery → ON CONFLICT (uq_cost_anomalies_open*) DO NOTHING.
-- The 24h "cooldown" semantic (don't re-emit the same anomaly type within
-- 24h) is preserved by the fact that an unresolved row blocks the insert
-- via the partial UNIQUE — same end state, race-free.
--
-- One subtle change: the old NOT EXISTS clause filtered on
-- `detected_at > now() - interval '24 hours'`. The new partial UNIQUE
-- filters on `resolved_at IS NULL` (no 24h window). For daily-spend
-- anomalies this is the operationally correct shape — a row that's been
-- unresolved for 25 hours is still "open" and shouldn't be re-emitted;
-- emitting twice would produce two Sentry alerts for the same anomaly.
-- The 24h window in the legacy logic was a duration-based dedup
-- expressed because PG can't have multi-row uniqueness without an
-- index — now it can, so we drop the window.

CREATE OR REPLACE FUNCTION public.stir_ops_cost_anomaly_scan()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_inserted              INTEGER := 0;
  v_daily_inserted        INTEGER := 0;
  v_voice_tokens_inserted INTEGER := 0;
  v_runaway_inserted      INTEGER := 0;
BEGIN
  -- ---- Daily spend anomalies (thresholds unchanged from 20260509144834).
  WITH daily AS (
    SELECT r.canonical_user_key,
           SUM(r.cost_usd) AS spend_24h,
           COUNT(*)        AS call_count
    FROM ai_request_log r
    WHERE r.created_at > now() - interval '24 hours'
    GROUP BY r.canonical_user_key
  ), tiered AS (
    SELECT d.canonical_user_key,
           d.spend_24h,
           d.call_count,
           COALESCE(es.tier::TEXT, 'free') AS tier,
           CASE
             WHEN d.spend_24h > 10.00 THEN 'daily_spend_hard_cap'
             WHEN COALESCE(es.tier::TEXT, 'free') = 'pro'     AND d.spend_24h > 8.00 THEN 'daily_spend_2x'
             WHEN COALESCE(es.tier::TEXT, 'free') = 'premium' AND d.spend_24h > 3.00 THEN 'daily_spend_2x'
             ELSE NULL
           END AS anomaly_type
    FROM daily d
    LEFT JOIN entitlement_snapshots es ON es.canonical_user_key = d.canonical_user_key
  ), to_insert AS (
    SELECT t.*,
           CASE t.anomaly_type
             WHEN 'daily_spend_hard_cap' THEN 'critical'
             ELSE 'warn'
           END AS severity,
           stir_hash_user_key(t.canonical_user_key) AS user_hash
    FROM tiered t
    WHERE t.anomaly_type IS NOT NULL
  )
  INSERT INTO cost_anomalies (canonical_user_key_hash, anomaly_type, severity, details_json)
  SELECT i.user_hash,
         i.anomaly_type::cost_anomaly_type,
         i.severity::cost_anomaly_severity,
         jsonb_build_object('tier', i.tier, 'spend_24h_usd', i.spend_24h, 'call_count', i.call_count)
  FROM to_insert i
  ON CONFLICT (canonical_user_key_hash, anomaly_type)
    WHERE resolved_at IS NULL
      AND anomaly_type IN ('daily_spend_2x', 'daily_spend_hard_cap')
    DO NOTHING;
  GET DIAGNOSTICS v_daily_inserted = ROW_COUNT;

  -- ---- Voice-session anomalies (SCA-121: index-backed via session_id).
  -- Branch 1: voice_session_tokens_over_cap (>50K cumulative tokens).
  WITH voice AS (
    SELECT session_id,
           canonical_user_key,
           SUM(input_tokens + output_tokens) AS total_tokens,
           COUNT(*)                          AS turn_count,
           MIN(created_at)                   AS started_at,
           MAX(created_at)                   AS last_turn_at
    FROM ai_request_log
    WHERE feature_key = 'cook_mode_realtime'
      AND session_id IS NOT NULL
      AND created_at > now() - interval '24 hours'
    GROUP BY session_id, canonical_user_key
  )
  INSERT INTO cost_anomalies (canonical_user_key_hash, anomaly_type, severity, details_json)
  SELECT stir_hash_user_key(v.canonical_user_key),
         'voice_session_tokens_over_cap'::cost_anomaly_type,
         'critical'::cost_anomaly_severity,
         jsonb_build_object(
           'session_id',    v.session_id::TEXT,
           'total_tokens',  v.total_tokens,
           'turn_count',    v.turn_count,
           'started_at',    v.started_at,
           'last_turn_at',  v.last_turn_at
         )
  FROM voice v
  WHERE v.total_tokens > 50000
  ON CONFLICT (canonical_user_key_hash, anomaly_type, (details_json->>'session_id'))
    WHERE resolved_at IS NULL
      AND anomaly_type IN ('voice_session_tokens_over_cap', 'runaway_session')
    DO NOTHING;
  GET DIAGNOSTICS v_voice_tokens_inserted = ROW_COUNT;

  -- Branch 2: runaway_session (>10-min span AND >20 turns).
  -- Re-runs the voice aggregate CTE because PG can't share CTEs across
  -- statements; see SCA-310 in docs/deferred-work.md for the materialize-once
  -- follow-up trigger.
  WITH voice2 AS (
    SELECT session_id,
           canonical_user_key,
           SUM(input_tokens + output_tokens) AS total_tokens,
           COUNT(*)                          AS turn_count,
           MIN(created_at)                   AS started_at,
           MAX(created_at)                   AS last_turn_at
    FROM ai_request_log
    WHERE feature_key = 'cook_mode_realtime'
      AND session_id IS NOT NULL
      AND created_at > now() - interval '24 hours'
    GROUP BY session_id, canonical_user_key
  )
  INSERT INTO cost_anomalies (canonical_user_key_hash, anomaly_type, severity, details_json)
  SELECT stir_hash_user_key(v.canonical_user_key),
         'runaway_session'::cost_anomaly_type,
         'critical'::cost_anomaly_severity,
         jsonb_build_object(
           'session_id',   v.session_id::TEXT,
           'turn_count',   v.turn_count,
           'duration_ms',  EXTRACT(EPOCH FROM (v.last_turn_at - v.started_at)) * 1000,
           'started_at',   v.started_at,
           'last_turn_at', v.last_turn_at,
           'total_tokens', v.total_tokens
         )
  FROM voice2 v
  WHERE v.turn_count > 20
    AND (v.last_turn_at - v.started_at) > interval '10 minutes'
  ON CONFLICT (canonical_user_key_hash, anomaly_type, (details_json->>'session_id'))
    WHERE resolved_at IS NULL
      AND anomaly_type IN ('voice_session_tokens_over_cap', 'runaway_session')
    DO NOTHING;
  GET DIAGNOSTICS v_runaway_inserted = ROW_COUNT;

  v_inserted := v_daily_inserted + v_voice_tokens_inserted + v_runaway_inserted;
  RETURN v_inserted;
END $$;

COMMENT ON FUNCTION public.stir_ops_cost_anomaly_scan() IS
  'SCA-303: TOCTOU-safe via ON CONFLICT DO NOTHING against partial UNIQUE indexes uq_cost_anomalies_open (daily-spend) + uq_cost_anomalies_open_session (per-session voice). Supersedes 20260509144834 dedup logic (NOT EXISTS race window). Daily-spend + voice-session anomaly detection unchanged.';
