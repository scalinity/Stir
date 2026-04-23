-- Stir operational schema — ops admin RPCs
-- Step 8 Phase 1.5: SECURITY DEFINER functions that back the ops-admin
-- Edge Function router. Split into two classes:
--
--   Admin RPCs (double-gated: EXECUTE TO service_role only + runtime
--   `is_admin() OR auth.role()='service_role'` check inside). The OR
--   clause is required because the ops-admin Edge Function calls these
--   via a service-role client — auth.uid() is NULL there, so pure
--   is_admin() would reject. The Edge Function's verifyAdminAuth is the
--   primary check; the internal gate is defense-in-depth against future
--   accidental over-granting (e.g. `GRANT EXECUTE TO authenticated`).
--   Direct PostgREST calls with admin JWTs (the hypothetical future
--   ops-SPA-direct path) satisfy is_admin() and also pass.
--
--   System RPCs (EXECUTE TO service_role only). Called by pg_cron jobs
--   (in-DB, no JWT context) or the ops-admin Edge Function for scheduled
--   work. No inner check because cron context has no auth.uid() AND
--   the cron-job caller runs as superuser (bypasses EXECUTE grants too).
--
-- All mutation RPCs write an audit_log row inline via app-level writeAudit
-- (from _shared/audit.ts) — NOT via SQL triggers. Rationale: the actor
-- identity comes from verifyAdminAuth (email + UUID), and pushing that
-- into a per-connection GUC just to have the trigger read it adds
-- coupling for no benefit over the explicit call from the handler.
--
-- Function names follow existing prefix convention: `stir_ops_*`.

-- pgcrypto is already available on Supabase by default (used by
-- gen_random_uuid in earlier migrations), but declare the intent.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- Utility: stir_hash_user_key
-- ---------------------------------------------------------------------------
-- SHA-256 over canonical_user_key, hex-encoded, truncated to 16 chars.
-- Mirrors functions/_shared/hashing.ts::hashCanonicalKey exactly so the
-- iOS-originating hash (used in telemetry) matches the SQL-originating
-- hash (used in cost_anomalies.canonical_user_key_hash, etc.).
-- IMMUTABLE so planners can fold constants + cache results.

CREATE OR REPLACE FUNCTION public.stir_hash_user_key(p_key TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = public, extensions
AS $$
  SELECT substring(encode(digest(p_key, 'sha256'), 'hex') FROM 1 FOR 16);
$$;

COMMENT ON FUNCTION public.stir_hash_user_key(TEXT) IS
  'SHA-256 truncated to 16 hex chars. Matches functions/_shared/hashing.ts::hashCanonicalKey. Use for every canonical_user_key_hash column insert/filter.';

-- ---------------------------------------------------------------------------
-- Admin RPC: stir_ops_list_users
-- ---------------------------------------------------------------------------
-- Paginated user list with filters. Returns a single JSONB blob:
--   { users: [...], total_count: int, limit: int, offset: int }
--
-- Args:
--   p_tier       'free' | 'premium' | 'pro' | NULL (any)
--   p_search     NULL or case-insensitive LIKE against canonical_user_key
--                 / revenuecat_app_user_id / current_install_id
--   p_limit      1..200 (default 50)
--   p_offset     >= 0
--
-- Row shape per user:
--   canonical_user_key, tier (from entitlement_snapshots), billing_state,
--   status, last_seen_at, created_at, ai_cost_usd_30d (from ai_request_log
--   aggregate), flagged_open_count (from ops_flagged_outputs).

CREATE OR REPLACE FUNCTION public.stir_ops_list_users(
  p_tier   TEXT    DEFAULT NULL,
  p_search TEXT    DEFAULT NULL,
  p_limit  INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_limit  INTEGER;
  v_offset INTEGER;
  v_tier   TEXT;
  v_search TEXT;
  v_total  INTEGER;
  v_users  JSONB;
BEGIN
  IF NOT (public.is_admin() OR COALESCE(auth.jwt() ->> 'role', '') = 'service_role') THEN
    RAISE EXCEPTION 'not admin' USING ERRCODE = '42501';
  END IF;

  v_limit  := GREATEST(1, LEAST(COALESCE(p_limit, 50), 200));
  v_offset := GREATEST(0, COALESCE(p_offset, 0));
  v_tier   := NULLIF(TRIM(COALESCE(p_tier, '')), '');
  v_search := NULLIF(TRIM(COALESCE(p_search, '')), '');

  WITH filtered AS (
    SELECT u.canonical_user_key,
           u.status,
           u.last_seen_at,
           u.created_at,
           u.current_install_id,
           u.revenuecat_app_user_id,
           u.reauth_required_at,
           COALESCE(es.tier::TEXT, 'free') AS tier,
           COALESCE(es.billing_state::TEXT, 'none') AS billing_state
    FROM app_users u
    LEFT JOIN entitlement_snapshots es
      ON es.canonical_user_key = u.canonical_user_key
    WHERE u.status != 'merged'
      AND (v_tier IS NULL OR COALESCE(es.tier::TEXT, 'free') = v_tier)
      AND (v_search IS NULL
           OR u.canonical_user_key ILIKE '%' || v_search || '%'
           OR COALESCE(u.revenuecat_app_user_id, '') ILIKE '%' || v_search || '%'
           OR COALESCE(u.current_install_id::TEXT, '') ILIKE '%' || v_search || '%')
  )
  SELECT COUNT(*) INTO v_total FROM filtered;

  WITH page AS (
    SELECT f.*
    FROM (
      SELECT u.canonical_user_key,
             u.status,
             u.last_seen_at,
             u.created_at,
             u.current_install_id,
             u.revenuecat_app_user_id,
             u.reauth_required_at,
             COALESCE(es.tier::TEXT, 'free') AS tier,
             COALESCE(es.billing_state::TEXT, 'none') AS billing_state
      FROM app_users u
      LEFT JOIN entitlement_snapshots es
        ON es.canonical_user_key = u.canonical_user_key
      WHERE u.status != 'merged'
        AND (v_tier IS NULL OR COALESCE(es.tier::TEXT, 'free') = v_tier)
        AND (v_search IS NULL
             OR u.canonical_user_key ILIKE '%' || v_search || '%'
             OR COALESCE(u.revenuecat_app_user_id, '') ILIKE '%' || v_search || '%'
             OR COALESCE(u.current_install_id::TEXT, '') ILIKE '%' || v_search || '%')
      ORDER BY u.last_seen_at DESC
      LIMIT v_limit OFFSET v_offset
    ) f
  ),
  enriched AS (
    SELECT p.canonical_user_key,
           p.tier,
           p.billing_state,
           p.status,
           p.last_seen_at,
           p.created_at,
           p.reauth_required_at,
           (SELECT COALESCE(SUM(r.cost_usd), 0)
              FROM ai_request_log r
             WHERE r.canonical_user_key = p.canonical_user_key
               AND r.created_at > now() - interval '30 days'
           ) AS ai_cost_usd_30d,
           (SELECT COUNT(*)
              FROM ops_flagged_outputs f
             WHERE f.canonical_user_key_hash = stir_hash_user_key(p.canonical_user_key)
               AND f.resolved_at IS NULL
           ) AS flagged_open_count
    FROM page p
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.last_seen_at DESC), '[]'::jsonb)
    INTO v_users
    FROM enriched e;

  RETURN jsonb_build_object(
    'users',       v_users,
    'total_count', v_total,
    'limit',       v_limit,
    'offset',      v_offset
  );
END $$;

COMMENT ON FUNCTION public.stir_ops_list_users(TEXT, TEXT, INTEGER, INTEGER) IS
  'Paginated user list for ops SPA. Filters: tier, search (ILIKE on canonical_user_key / RC ID / install_id). Returns { users, total_count, limit, offset }. Admin-gated via is_admin().';

-- ---------------------------------------------------------------------------
-- Admin RPC: stir_ops_user_detail
-- ---------------------------------------------------------------------------
-- Aggregator for the user-detail page. One round trip returns everything
-- the ops SPA needs to render a user row: profile + entitlement +
-- current-period quotas + recent AI calls + recent webhook deliveries +
-- open flagged outputs.

CREATE OR REPLACE FUNCTION public.stir_ops_user_detail(p_canonical_user_key TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
  v_hash   TEXT;
BEGIN
  IF NOT (public.is_admin() OR COALESCE(auth.jwt() ->> 'role', '') = 'service_role') THEN
    RAISE EXCEPTION 'not admin' USING ERRCODE = '42501';
  END IF;

  v_hash := stir_hash_user_key(p_canonical_user_key);

  SELECT jsonb_build_object(
    'user',        (SELECT to_jsonb(u) FROM app_users u WHERE u.canonical_user_key = p_canonical_user_key),
    'entitlement', (SELECT to_jsonb(es) FROM entitlement_snapshots es WHERE es.canonical_user_key = p_canonical_user_key),
    'quotas',      COALESCE((SELECT jsonb_agg(to_jsonb(uc) ORDER BY uc.feature_key)
                              FROM usage_counters uc
                             WHERE uc.canonical_user_key = p_canonical_user_key
                               AND uc.period_start = (
                                   SELECT MAX(period_start) FROM usage_counters
                                   WHERE canonical_user_key = p_canonical_user_key
                               )), '[]'::jsonb),
    'ai_recent',   COALESCE((SELECT jsonb_agg(to_jsonb(r)) FROM (
                              SELECT request_id, feature_key, model, input_tokens, output_tokens,
                                     cost_usd, latency_ms, thinking_level, prompt_version,
                                     retry_count, created_at
                                FROM ai_request_log
                               WHERE canonical_user_key = p_canonical_user_key
                               ORDER BY created_at DESC
                               LIMIT 100
                             ) r), '[]'::jsonb),
    'webhooks',    COALESCE((SELECT jsonb_agg(to_jsonb(w)) FROM (
                              SELECT event_id, event_type, status, processed_at
                                FROM webhook_log
                               WHERE canonical_user_key = p_canonical_user_key
                               ORDER BY processed_at DESC
                               LIMIT 50
                             ) w), '[]'::jsonb),
    'flagged_open', COALESCE((SELECT jsonb_agg(to_jsonb(f)) FROM (
                               SELECT id, feature_key, request_id, flagged_by, flag_reason,
                                      created_at
                                 FROM ops_flagged_outputs
                                WHERE canonical_user_key_hash = v_hash
                                  AND resolved_at IS NULL
                                ORDER BY created_at DESC
                                LIMIT 20
                              ) f), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END $$;

COMMENT ON FUNCTION public.stir_ops_user_detail(TEXT) IS
  'Aggregator for user detail page: profile + entitlement + current-period quotas + recent AI + webhooks + open flagged outputs. Admin-gated.';

-- ---------------------------------------------------------------------------
-- Admin RPC: stir_ops_reset_quota
-- ---------------------------------------------------------------------------
-- Zeroes used_count for a given user + feature_key in the CURRENT period.
-- Returns a { before, after } snapshot for the audit log. Idempotent —
-- re-running against an already-zero row is a no-op + same snapshot.
--
-- cap_count is NOT reset; it snapshots at period_start per CLAUDE.md §
-- usage_counters semantics.

CREATE OR REPLACE FUNCTION public.stir_ops_reset_quota(
  p_canonical_user_key TEXT,
  p_feature_key        usage_feature_key
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_before JSONB;
  v_after  JSONB;
  v_now_period DATE;
BEGIN
  IF NOT (public.is_admin() OR COALESCE(auth.jwt() ->> 'role', '') = 'service_role') THEN
    RAISE EXCEPTION 'not admin' USING ERRCODE = '42501';
  END IF;

  -- Current-period row. period_start is anchored on app_users.created_at
  -- month-day (per CLAUDE.md); we just read the max period_start for this
  -- user + feature. If the user has no row yet (never incremented the
  -- counter), there's nothing to zero — return null snapshot.
  SELECT to_jsonb(uc) INTO v_before
  FROM usage_counters uc
  WHERE uc.canonical_user_key = p_canonical_user_key
    AND uc.feature_key = p_feature_key
    AND uc.period_start = (
      SELECT MAX(period_start) FROM usage_counters
      WHERE canonical_user_key = p_canonical_user_key
        AND feature_key = p_feature_key
    );

  IF v_before IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'before', NULL, 'after', NULL, 'noop', true);
  END IF;

  v_now_period := (v_before->>'period_start')::DATE;

  UPDATE usage_counters
     SET used_count = 0,
         updated_at = now()
   WHERE canonical_user_key = p_canonical_user_key
     AND feature_key = p_feature_key
     AND period_start = v_now_period
   RETURNING to_jsonb(usage_counters.*) INTO v_after;

  RETURN jsonb_build_object('ok', true, 'before', v_before, 'after', v_after);
END $$;

COMMENT ON FUNCTION public.stir_ops_reset_quota(TEXT, usage_feature_key) IS
  'Zeroes used_count for the current period (cap_count preserved). Returns { before, after } for audit. Admin-gated.';

-- ---------------------------------------------------------------------------
-- Admin RPC: stir_ops_set_user_status
-- ---------------------------------------------------------------------------
-- Transitions app_users.status between active ↔ banned. Refuses merged
-- (that's a system-only terminal state). Returns { before, after } for
-- audit.

CREATE OR REPLACE FUNCTION public.stir_ops_set_user_status(
  p_canonical_user_key TEXT,
  p_status             app_user_status
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_before JSONB;
  v_after  JSONB;
BEGIN
  IF NOT (public.is_admin() OR COALESCE(auth.jwt() ->> 'role', '') = 'service_role') THEN
    RAISE EXCEPTION 'not admin' USING ERRCODE = '42501';
  END IF;

  IF p_status = 'merged' THEN
    RAISE EXCEPTION 'cannot manually set status to merged (system-only terminal state)'
      USING ERRCODE = '22023';  -- invalid_parameter_value
  END IF;

  SELECT to_jsonb(u) INTO v_before
    FROM app_users u
   WHERE u.canonical_user_key = p_canonical_user_key;

  IF v_before IS NULL THEN
    RAISE EXCEPTION 'user not found: %', p_canonical_user_key
      USING ERRCODE = '22023';
  END IF;

  -- Reject transition FROM merged (terminal).
  IF (v_before->>'status') = 'merged' THEN
    RAISE EXCEPTION 'cannot transition from merged (terminal state)'
      USING ERRCODE = '22023';
  END IF;

  UPDATE app_users
     SET status = p_status
   WHERE canonical_user_key = p_canonical_user_key
   RETURNING to_jsonb(app_users.*) INTO v_after;

  RETURN jsonb_build_object('ok', true, 'before', v_before, 'after', v_after);
END $$;

COMMENT ON FUNCTION public.stir_ops_set_user_status(TEXT, app_user_status) IS
  'Transition active ↔ banned. Refuses merged (system-only). Returns { before, after } for audit. Admin-gated.';

-- ---------------------------------------------------------------------------
-- Admin RPC: stir_ops_force_reauth
-- ---------------------------------------------------------------------------
-- Sets app_users.reauth_required_at = now(). Phase-2 verifySessionJWT
-- compares JWT.iat; existing JWTs with iat < now() are rejected with
-- AUTH-01 reason=reauth_required on their next verifying call.
--
-- Idempotent: re-calling simply bumps the timestamp, invalidating any
-- JWTs issued between the first and second call.

CREATE OR REPLACE FUNCTION public.stir_ops_force_reauth(
  p_canonical_user_key TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_before JSONB;
  v_after  JSONB;
BEGIN
  IF NOT (public.is_admin() OR COALESCE(auth.jwt() ->> 'role', '') = 'service_role') THEN
    RAISE EXCEPTION 'not admin' USING ERRCODE = '42501';
  END IF;

  SELECT to_jsonb(u) INTO v_before
    FROM app_users u
   WHERE u.canonical_user_key = p_canonical_user_key;

  IF v_before IS NULL THEN
    RAISE EXCEPTION 'user not found: %', p_canonical_user_key
      USING ERRCODE = '22023';
  END IF;

  UPDATE app_users
     SET reauth_required_at = now()
   WHERE canonical_user_key = p_canonical_user_key
   RETURNING to_jsonb(app_users.*) INTO v_after;

  RETURN jsonb_build_object('ok', true, 'before', v_before, 'after', v_after);
END $$;

COMMENT ON FUNCTION public.stir_ops_force_reauth(TEXT) IS
  'Bumps app_users.reauth_required_at = now(). Phase-2 verifySessionJWT rejects JWTs with iat < this on next call. iOS handles AUTH-01 reason=reauth_required by triggering Sign-in-with-Apple re-flow. Admin-gated.';

-- ---------------------------------------------------------------------------
-- Admin RPC: stir_ops_list_voice_sessions
-- ---------------------------------------------------------------------------
-- Aggregates ai_request_log by trace_id where feature_key='cook_mode_realtime'
-- (= voice Cook sessions). Sorted by cumulative_prompt_tokens DESC to
-- surface outliers for the Voice Sessions ops page (spec §14 page 3).
--
-- Filters:
--   p_since          floor on MIN(r.created_at) (default: 24h ago)
--   p_min_tokens     floor on SUM(prompt+response) (default: 0; set to
--                    50000 to find sessions that tripped the runaway
--                    cost anomaly threshold)
--   p_limit          row cap (default 100)
--
-- Session_id extraction: voice-turn-usage writes rows with
--   request_id = 'voice:<session_id>:<turn_index>'
-- (see voice-turn-usage/index.ts), so we peel session_id out of the
-- request_id via split_part. Rows whose request_id doesn't match the
-- 'voice:*:*' shape are excluded — which also safely excludes any
-- stray non-voice feature_key leakage (belt-and-suspenders with the
-- feature_key filter).

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
    SELECT split_part(request_id, ':', 2) AS session_id,
           canonical_user_key,
           COUNT(*)               AS turn_count,
           SUM(input_tokens)      AS cumulative_prompt_tokens,
           SUM(output_tokens)     AS cumulative_response_tokens,
           SUM(cost_usd)          AS total_cost_usd,
           MIN(created_at)        AS started_at,
           MAX(created_at)        AS last_turn_at
    FROM ai_request_log
    WHERE feature_key = 'cook_mode_realtime'
      AND request_id LIKE 'voice:%:%'
      AND created_at >= v_since
    GROUP BY split_part(request_id, ':', 2), canonical_user_key
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
  'Voice Cook sessions aggregated by session_id extracted from request_id=voice:<session_id>:<turn>. Sorted by cumulative prompt tokens DESC. Backs spec §14 page 3 "Voice Sessions". Admin-gated.';

-- ---------------------------------------------------------------------------
-- System RPC: stir_ops_cost_anomaly_scan
-- ---------------------------------------------------------------------------
-- Cron-invoked detector. Inserts new cost_anomalies rows for users
-- crossing any threshold in the last 24h that don't already have an
-- unresolved row for the same anomaly_type in the same window.
--
-- Thresholds (spec §13 alerts):
--   daily_spend_hard_cap  ANY user > $10/day (critical)
--   daily_spend_2x        Pro > $8/day OR Premium > $3/day (warn)
--   voice_session_tokens_over_cap  session cumulative tokens > 50K (critical)
--
-- Returns inserted row count. No Sentry-dispatch inside — a follow-up
-- pg_cron job reads cost_anomalies WHERE alerted_at IS NULL and POSTs
-- via pg_net (keeps this function pure / testable).

CREATE OR REPLACE FUNCTION public.stir_ops_cost_anomaly_scan()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_inserted INTEGER := 0;
  v_daily_inserted INTEGER := 0;
  v_voice_inserted INTEGER := 0;
BEGIN
  -- Daily spend anomalies: any user whose 24h spend crossed a threshold.
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

  -- Voice-session runaway: cumulative tokens on a single session_id > 50K.
  -- session_id extracted from request_id=voice:<session>:<turn> per
  -- voice-turn-usage/index.ts convention.
  WITH voice AS (
    SELECT split_part(request_id, ':', 2) AS session_id,
           canonical_user_key,
           SUM(input_tokens + output_tokens) AS total_tokens,
           COUNT(*) AS turn_count,
           MIN(created_at) AS started_at,
           MAX(created_at) AS last_turn_at
    FROM ai_request_log
    WHERE feature_key = 'cook_mode_realtime'
      AND request_id LIKE 'voice:%:%'
      AND created_at > now() - interval '24 hours'
    GROUP BY split_part(request_id, ':', 2), canonical_user_key
    HAVING SUM(input_tokens + output_tokens) > 50000
  )
  INSERT INTO cost_anomalies (canonical_user_key_hash, anomaly_type, severity, details_json)
  SELECT stir_hash_user_key(v.canonical_user_key),
         'voice_session_tokens_over_cap'::cost_anomaly_type,
         'critical'::cost_anomaly_severity,
         jsonb_build_object(
           'session_id',    v.session_id,
           'total_tokens',  v.total_tokens,
           'turn_count',    v.turn_count,
           'started_at',    v.started_at,
           'last_turn_at',  v.last_turn_at
         )
  FROM voice v
  WHERE NOT EXISTS (
    SELECT 1 FROM cost_anomalies ca
    WHERE ca.canonical_user_key_hash = stir_hash_user_key(v.canonical_user_key)
      AND ca.anomaly_type = 'voice_session_tokens_over_cap'::cost_anomaly_type
      AND ca.details_json->>'session_id' = v.session_id
      AND ca.resolved_at IS NULL
  );
  GET DIAGNOSTICS v_voice_inserted = ROW_COUNT;

  v_inserted := v_daily_inserted + v_voice_inserted;
  RETURN v_inserted;
END $$;

COMMENT ON FUNCTION public.stir_ops_cost_anomaly_scan() IS
  'Cron-invoked detector. Inserts cost_anomalies rows for users crossing 24h-window thresholds. Dedup via NOT EXISTS against unresolved rows within 24h. No Sentry dispatch inside — separate job handles alerted_at IS NULL.';

-- ---------------------------------------------------------------------------
-- System RPC: stir_ops_reactivation_enqueue
-- ---------------------------------------------------------------------------
-- Cron-invoked daily (10am PT ≈ 18 UTC, see migration 000010). Inserts
-- notification_jobs rows of kind='push_send' for users who:
--   - haven't been seen in between 14 and 21 days
--   - have an active account (status='active')
--   - have a push_token on their most-recent device_installations row
--   - haven't opted out of reactivation pushes
--   - haven't received a reactivation push in the last 30 days

CREATE OR REPLACE FUNCTION public.stir_ops_reactivation_enqueue(
  p_inactive_days  INTEGER DEFAULT 14,
  p_window_end_days INTEGER DEFAULT 21
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_inserted INTEGER := 0;
BEGIN
  WITH candidates AS (
    SELECT DISTINCT ON (u.canonical_user_key)
           u.canonical_user_key,
           di.push_token,
           di.apns_environment
    FROM app_users u
    JOIN device_installations di USING (canonical_user_key)
    WHERE u.last_seen_at BETWEEN now() - make_interval(days => p_window_end_days)
                             AND now() - make_interval(days => p_inactive_days)
      AND u.status = 'active'
      AND di.push_token IS NOT NULL
      AND COALESCE((di.notification_prefs_json->>'reactivation')::boolean, true) = true
      AND NOT EXISTS (
        SELECT 1 FROM notification_jobs nj
        WHERE nj.canonical_user_key = u.canonical_user_key
          AND nj.kind = 'push_send'
          AND nj.payload_json->>'template' = 'reactivation'
          AND nj.created_at > now() - interval '30 days'
      )
    ORDER BY u.canonical_user_key, di.last_seen_at DESC
  )
  INSERT INTO notification_jobs (canonical_user_key, kind, payload_json, scheduled_at)
  SELECT c.canonical_user_key,
         'push_send'::notification_job_kind,
         jsonb_build_object(
           'template',    'reactivation',
           'title',       'What''s for dinner?',
           'body',        'Haven''t cooked in a while? See what tonight''s dinner could be.',
           'deep_link',   'stir://tonight?trigger=reactivation',
           'apns_token',  c.push_token,
           'environment', c.apns_environment
         ),
         now()
  FROM candidates c;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  RETURN v_inserted;
END $$;

COMMENT ON FUNCTION public.stir_ops_reactivation_enqueue(INTEGER, INTEGER) IS
  'Cron-invoked daily. Seeds notification_jobs push_send rows for inactive users (14-21 days, active, push-enabled, not-recently-nudged). Returns insert count.';

-- ---------------------------------------------------------------------------
-- Grants: service_role only.
-- ---------------------------------------------------------------------------
-- REVOKE first to clear any GRANT-BY-DEFAULT from PUBLIC; then GRANT only
-- to service_role. PostgREST rejects calls from authenticated/anon with
-- "permission denied" — that's fine; ops-admin Edge Function uses service
-- client anyway.

REVOKE ALL ON FUNCTION public.stir_ops_list_users(TEXT, TEXT, INTEGER, INTEGER)          FROM PUBLIC, authenticated, anon;
REVOKE ALL ON FUNCTION public.stir_ops_user_detail(TEXT)                                  FROM PUBLIC, authenticated, anon;
REVOKE ALL ON FUNCTION public.stir_ops_reset_quota(TEXT, usage_feature_key)               FROM PUBLIC, authenticated, anon;
REVOKE ALL ON FUNCTION public.stir_ops_set_user_status(TEXT, app_user_status)             FROM PUBLIC, authenticated, anon;
REVOKE ALL ON FUNCTION public.stir_ops_force_reauth(TEXT)                                 FROM PUBLIC, authenticated, anon;
REVOKE ALL ON FUNCTION public.stir_ops_list_voice_sessions(TIMESTAMPTZ, INTEGER, INTEGER) FROM PUBLIC, authenticated, anon;
REVOKE ALL ON FUNCTION public.stir_ops_cost_anomaly_scan()                                FROM PUBLIC, authenticated, anon;
REVOKE ALL ON FUNCTION public.stir_ops_reactivation_enqueue(INTEGER, INTEGER)             FROM PUBLIC, authenticated, anon;

GRANT EXECUTE ON FUNCTION public.stir_ops_list_users(TEXT, TEXT, INTEGER, INTEGER)          TO service_role;
GRANT EXECUTE ON FUNCTION public.stir_ops_user_detail(TEXT)                                  TO service_role;
GRANT EXECUTE ON FUNCTION public.stir_ops_reset_quota(TEXT, usage_feature_key)               TO service_role;
GRANT EXECUTE ON FUNCTION public.stir_ops_set_user_status(TEXT, app_user_status)             TO service_role;
GRANT EXECUTE ON FUNCTION public.stir_ops_force_reauth(TEXT)                                 TO service_role;
GRANT EXECUTE ON FUNCTION public.stir_ops_list_voice_sessions(TIMESTAMPTZ, INTEGER, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.stir_ops_cost_anomaly_scan()                                TO service_role;
GRANT EXECUTE ON FUNCTION public.stir_ops_reactivation_enqueue(INTEGER, INTEGER)             TO service_role;

-- stir_hash_user_key is utility; safe for anyone to call (it's pure
-- and takes a text arg). Keep EXECUTE open to match other utility
-- helpers in the codebase.
GRANT EXECUTE ON FUNCTION public.stir_hash_user_key(TEXT) TO PUBLIC;
