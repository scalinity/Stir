-- SCA-121 — rewrite voice anomaly detectors to use ai_request_log.session_id
-- directly (index-backed via idx_ai_request_log_voice_session) and add the
-- runaway_session detector branch.
--
-- Background:
--   * Migration 20260424000003 added `ai_request_log.session_id UUID` plus
--     a partial composite index `idx_ai_request_log_voice_session` keyed on
--     (feature_key, session_id, created_at DESC) WHERE feature_key=
--     'cook_mode_realtime' AND session_id IS NOT NULL.
--   * The legacy detector path (`stir_ops_cost_anomaly_scan` voice branch
--     and `stir_ops_list_voice_sessions`) still extracted session_id with
--     `split_part(request_id, ':', 2)` and filtered with `request_id LIKE
--     'voice:%:%'` — both expressions are index-incompatible, forcing a
--     sequential scan of ai_request_log every 15 minutes (cron cadence).
--   * The `runaway_session` ENUM value was declared in migration
--     20260423000008 but no detector ever populated it. Spec §13 names
--     "single session > 10 min AND > 20 turns" as the threshold; this
--     detector closes that gap.
--
-- Forward-only supersession: re-`CREATE OR REPLACE` both functions with
-- the index-backed shape. Original migration `20260423000009` stays
-- immutable per CLAUDE.md immutable-migration policy; this dated migration
-- holds the canonical definition going forward.
--
-- Backfill posture: rows older than 20260424000003 already had session_id
-- populated by that migration's UPDATE statement. Rows after that came
-- in with the column populated at insert time (voice-turn-usage handler).
-- Either way the partial index is correct for any row we're querying in
-- the 24-hour analysis window today.

-- ---------------------------------------------------------------------------
-- stir_ops_list_voice_sessions — index-backed rewrite
-- ---------------------------------------------------------------------------
-- Behavior unchanged: same arguments, same JSONB return shape, same
-- admin gate. Only the WHERE/GROUP BY shape changes from the
-- request_id-pattern legacy expression to the session_id column.
-- The partial index `idx_ai_request_log_voice_session` covers the new
-- query directly — feature_key='cook_mode_realtime' filter +
-- session_id IS NOT NULL filter + created_at >= since range scan.

CREATE OR REPLACE FUNCTION public.stir_ops_list_voice_sessions(
  p_since      TIMESTAMPTZ DEFAULT NULL,
  p_min_tokens INTEGER     DEFAULT 0,
  p_limit      INTEGER     DEFAULT 100
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_since  TIMESTAMPTZ;
  v_limit  INTEGER;
  v_min    INTEGER;
  v_rows   JSONB;
BEGIN
  IF NOT (public.is_admin() OR COALESCE(auth.jwt() ->> 'role', '') = 'service_role') THEN
    RAISE EXCEPTION 'not admin' USING ERRCODE = '42501';
  END IF;

  v_since := COALESCE(p_since, now() - interval '24 hours');
  v_limit := GREATEST(1, LEAST(COALESCE(p_limit, 100), 500));
  v_min   := GREATEST(0, COALESCE(p_min_tokens, 0));

  WITH grouped AS (
    SELECT session_id::TEXT      AS session_id,
           canonical_user_key,
           COUNT(*)               AS turn_count,
           SUM(input_tokens)      AS cumulative_prompt_tokens,
           SUM(output_tokens)     AS cumulative_response_tokens,
           SUM(cost_usd)          AS total_cost_usd,
           MIN(created_at)        AS started_at,
           MAX(created_at)        AS last_turn_at
    FROM ai_request_log
    WHERE feature_key = 'cook_mode_realtime'
      AND session_id IS NOT NULL
      AND created_at >= v_since
    GROUP BY session_id, canonical_user_key
    HAVING SUM(input_tokens + output_tokens) >= v_min
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'session_id',                 g.session_id,
      'canonical_user_key_hash',    stir_hash_user_key(g.canonical_user_key),
      'turn_count',                 g.turn_count,
      'cumulative_prompt_tokens',   g.cumulative_prompt_tokens,
      'cumulative_response_tokens', g.cumulative_response_tokens,
      'total_cost_usd',             g.total_cost_usd,
      'started_at',                 g.started_at,
      'last_turn_at',               g.last_turn_at,
      'duration_sec',               EXTRACT(EPOCH FROM (g.last_turn_at - g.started_at))
    )
    ORDER BY g.cumulative_prompt_tokens DESC
  ), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT * FROM grouped
    ORDER BY cumulative_prompt_tokens DESC
    LIMIT v_limit
  ) g;

  RETURN jsonb_build_object('sessions', v_rows, 'since', v_since, 'min_tokens', v_min, 'limit', v_limit);
END $$;

COMMENT ON FUNCTION public.stir_ops_list_voice_sessions(TIMESTAMPTZ, INTEGER, INTEGER) IS
  'SCA-121: Voice Cook sessions aggregated by ai_request_log.session_id (index-backed via idx_ai_request_log_voice_session). Sorted by cumulative prompt tokens DESC. Backs spec §14 page 3 "Voice Sessions". Admin-gated.';

-- ---------------------------------------------------------------------------
-- stir_ops_cost_anomaly_scan — index-backed rewrite + runaway_session
-- ---------------------------------------------------------------------------
-- Daily-spend branches unchanged. Voice branches both rewritten to the
-- index-backed shape, plus a new `runaway_session` detector branch:
-- emits a critical anomaly when a single session_id has > 10-min span
-- (last_turn_at - started_at > 10 min) AND > 20 turns (turn_count > 20).
-- Severity: critical (CLAUDE.md North-star §6 — voice is the highest-cost
-- vendor relationship; a runaway session is a cost-anomaly red flag,
-- whether token-bound or not).

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
  -- ---- Daily spend anomalies (unchanged from 20260423000009).
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
  WHERE NOT EXISTS (
    SELECT 1 FROM cost_anomalies ca
    WHERE ca.canonical_user_key_hash = i.user_hash
      AND ca.anomaly_type            = i.anomaly_type::cost_anomaly_type
      AND ca.detected_at > now() - interval '24 hours'
      AND ca.resolved_at IS NULL
  );
  GET DIAGNOSTICS v_daily_inserted = ROW_COUNT;

  -- ---- Voice-session anomalies (SCA-121: index-backed via session_id).
  -- One CTE produces the per-session aggregate; two INSERTs read from it
  -- with different HAVING-style filters. Splitting the inserts (rather
  -- than UNION ALL with a CASE) keeps the dedup NOT EXISTS clauses
  -- cleanly per-anomaly-type so a row that trips both thresholds
  -- (>50K tokens AND >10min/>20turns) emits exactly one row of each
  -- type — the operationally correct behavior since they have
  -- different ops semantics.
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
  -- Branch 1: voice_session_tokens_over_cap (>50K cumulative tokens).
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
    AND NOT EXISTS (
      SELECT 1 FROM cost_anomalies ca
      WHERE ca.canonical_user_key_hash = stir_hash_user_key(v.canonical_user_key)
        AND ca.anomaly_type = 'voice_session_tokens_over_cap'::cost_anomaly_type
        AND ca.details_json->>'session_id' = v.session_id::TEXT
        AND ca.resolved_at IS NULL
    );
  GET DIAGNOSTICS v_voice_tokens_inserted = ROW_COUNT;

  -- Branch 2: runaway_session (>10-min span AND >20 turns).
  -- Reuses the same `voice` CTE — but PG can't share a CTE across
  -- statements, so we re-run the aggregation. The partial index keeps
  -- this cheap.
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
    AND NOT EXISTS (
      SELECT 1 FROM cost_anomalies ca
      WHERE ca.canonical_user_key_hash = stir_hash_user_key(v.canonical_user_key)
        AND ca.anomaly_type = 'runaway_session'::cost_anomaly_type
        AND ca.details_json->>'session_id' = v.session_id::TEXT
        AND ca.resolved_at IS NULL
    );
  GET DIAGNOSTICS v_runaway_inserted = ROW_COUNT;

  v_inserted := v_daily_inserted + v_voice_tokens_inserted + v_runaway_inserted;
  RETURN v_inserted;
END $$;

COMMENT ON FUNCTION public.stir_ops_cost_anomaly_scan() IS
  'SCA-121: Cron-invoked detector. Daily-spend + voice-session anomalies (token-cap and runaway-session). Voice branches read ai_request_log.session_id directly (index-backed via idx_ai_request_log_voice_session). Dedup via NOT EXISTS against unresolved rows within 24h.';
