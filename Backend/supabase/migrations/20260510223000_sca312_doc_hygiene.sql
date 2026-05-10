-- SCA-312 (/review-5 S10 + S19 + S20) — backend doc hygiene migration.
--
-- Three doc-only drifts to fix forward (immutable-migration policy):
--
--   S10. cost_anomalies.details_json column COMMENT was set in
--        20260423000008_init_cost_anomalies.sql to "Snapshot of metrics
--        at detection time. Shape varies by anomaly_type. See migration
--        comment." — but the migration comment it points to no longer
--        documents the per-anomaly_type shape after SCA-121's voice
--        rewrite (20260509144834) introduced `runaway_session` and
--        canonicalized the voice token-cap shape. Restate the COMMENT
--        with the literal shapes the proc emits today, so the column
--        is self-documenting without chasing migration history.
--
--   S19. stir_pgmq_reclaim_sweep (20260509145809) has an inline plpgsql
--        comment at lines 53-55 that calls the bad-input branch a
--        "clamp" — but the branch RESETS p_stale_minutes to the default
--        (5) when the input is NULL or < 1, it doesn't clamp at a floor.
--        Same shape for p_max_attempts (resets to 3). CREATE OR REPLACE
--        the proc with corrected comment; behavior unchanged.
--
--   S20. stir_ops_cost_anomaly_scan (after SCA-303's
--        20260510221200_cost_anomalies_partial_unique_index.sql) tests
--        runaway_session with `v.turn_count > 20 AND (v.last_turn_at -
--        v.started_at) > interval '10 minutes'`. The strict-greater-than
--        on both bounds is intentional (spec §13 literal: ">10 min AND
--        >20 turns", not ≥), but the SQL doesn't say so inline — easy
--        to "fix" to `>=` by a reader assuming inclusive bounds. Add a
--        guard comment. CREATE OR REPLACE the proc with the comment;
--        behavior unchanged.
--
-- All three changes preserve final-state semantics; this is pure doc
-- hygiene. No CHECK / index / data changes.

-- ---------------------------------------------------------------------------
-- S10: cost_anomalies.details_json shape COMMENT
-- ---------------------------------------------------------------------------

COMMENT ON COLUMN cost_anomalies.details_json IS
  $$Snapshot of metrics at detection time. Shape varies by anomaly_type:

    daily_spend_2x / daily_spend_hard_cap:
      { tier: 'free'|'premium'|'pro', spend_24h_usd: numeric, call_count: int }

    voice_session_tokens_over_cap:
      { session_id: uuid::TEXT, total_tokens: int, turn_count: int,
        started_at: timestamptz, last_turn_at: timestamptz }

    runaway_session:
      { session_id: uuid::TEXT, turn_count: int, duration_ms: numeric,
        started_at: timestamptz, last_turn_at: timestamptz,
        total_tokens: int }

  Shape canonicalized by SCA-121 (20260509144834) + SCA-303
  (20260510221200). The partial UNIQUE index uq_cost_anomalies_open_session
  reads `details_json->>'session_id'` so the key MUST be present (and
  spelled `session_id`) on the two voice anomaly_types.$$;

-- ---------------------------------------------------------------------------
-- S19: stir_pgmq_reclaim_sweep — fix "clamp" misnomer in inline comment
-- ---------------------------------------------------------------------------
-- Body byte-identical to 20260509145809 except for the comment block at
-- the top of the BEGIN. Re-issued here via CREATE OR REPLACE; the
-- 20260509145809 file stays immutable. Function semantics unchanged.

CREATE OR REPLACE FUNCTION public.stir_pgmq_reclaim_sweep(
  p_stale_minutes INTEGER DEFAULT 5,
  p_max_attempts  INTEGER DEFAULT 3
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cutoff           TIMESTAMPTZ;
  v_reclaimed_count  INTEGER := 0;
  v_dead_lettered    INTEGER := 0;
BEGIN
  -- SCA-312 S19: bad input (NULL or < 1) RESETS the parameter to the
  -- function default (5 for stale-minutes, 3 for max-attempts). It is
  -- NOT a "clamp" — a clamp would pin to the boundary (1), this
  -- restores the safe default. Documented because reading "clamp" and
  -- expecting a floor of 1 produces wrong intuition about what a misuse
  -- looks like in logs (`p_stale_minutes := 5` not `:= 1`).
  IF p_stale_minutes IS NULL OR p_stale_minutes < 1 THEN
    p_stale_minutes := 5;
  END IF;
  IF p_max_attempts IS NULL OR p_max_attempts < 1 THEN
    p_max_attempts := 3;
  END IF;

  v_cutoff := now() - (p_stale_minutes || ' minutes')::interval;

  -- ---- Part A: reclaim to 'pending' for retry.
  WITH reclaimed AS (
    UPDATE notification_jobs
       SET state = 'pending',
           error_message = 'reclaimed after stuck processing window',
           updated_at = now()
     WHERE state = 'processing'
       AND attempt_count < p_max_attempts
       AND updated_at < v_cutoff
    RETURNING id
  )
  SELECT COUNT(*) INTO v_reclaimed_count FROM reclaimed;

  -- ---- Part B: dead-letter to 'failed'.
  WITH dead_lettered AS (
    UPDATE notification_jobs
       SET state = 'failed',
           error_message = 'reclaim_max_attempts_reached',
           updated_at = now(),
           processed_at = now()
     WHERE state = 'processing'
       AND attempt_count >= p_max_attempts
       AND updated_at < v_cutoff
    RETURNING id
  )
  SELECT COUNT(*) INTO v_dead_lettered FROM dead_lettered;

  RETURN jsonb_build_object(
    'reclaimed_count',     v_reclaimed_count,
    'dead_lettered_count', v_dead_lettered,
    'cutoff',              v_cutoff,
    'stale_minutes',       p_stale_minutes,
    'max_attempts',        p_max_attempts
  );
END $$;

COMMENT ON FUNCTION public.stir_pgmq_reclaim_sweep(INTEGER, INTEGER) IS
  'SCA-125 + SCA-312: pgmq-dispatch reclaim sweep. Part A reclaims state=processing rows under the retry budget back to pending; Part B dead-letters rows at attempt_count >= max to failed. Bad-input branch RESETS params to default (not clamp). Service-role only.';

REVOKE ALL ON FUNCTION public.stir_pgmq_reclaim_sweep(INTEGER, INTEGER)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.stir_pgmq_reclaim_sweep(INTEGER, INTEGER)
  TO service_role;

-- ---------------------------------------------------------------------------
-- S20: stir_ops_cost_anomaly_scan — pin the strict-greater-than intent
-- ---------------------------------------------------------------------------
-- Body byte-identical to SCA-303's 20260510221200 except for one inline
-- comment at the runaway_session WHERE clause. Re-issued via CREATE OR
-- REPLACE; the 20260510221200 file stays immutable. ON CONFLICT shape,
-- thresholds, and dedup semantics unchanged.

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
  -- ---- Daily spend anomalies.
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

  -- ---- Voice-session anomalies: branch 1 (token-cap).
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

  -- ---- Voice-session anomalies: branch 2 (runaway_session).
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
  -- SCA-312 S20: both bounds use strict `>` intentionally — spec §13
  -- defines the runaway-session threshold as ">10 min AND >20 turns",
  -- NOT inclusive. The 20-turns-over-9-minutes and 20-turns-over-11-minutes
  -- regression tests in tests/integration/cost_anomaly_scan_test.ts
  -- pin both gates as strict, so a "fix" from `>` to `>=` will fail
  -- the suite. Do not relax without amending the spec.
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
  'SCA-303 + SCA-312: TOCTOU-safe via ON CONFLICT DO NOTHING. Strict-> thresholds intentional per spec §13. Supersedes 20260510221200 doc only.';
