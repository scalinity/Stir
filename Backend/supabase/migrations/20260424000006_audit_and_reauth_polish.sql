-- Step-8 review W34 + W39 + W12 — audit fidelity + merged force_reauth +
-- reactivation advisory lock.
--
--  W34 (CA1 #6): stir_ops_reset_quota had SELECT-then-UPDATE race producing
--                stale audit `before`. Fix: SELECT ... FOR UPDATE locks the
--                row, eliminating concurrent-increment race between SELECT
--                and UPDATE.
--
--  W39 (DB1 #5): stir_ops_force_reauth did not cascade to merged_into
--                chain. Alias-forwarded install JWTs would bypass force_reauth
--                on their target. Fix: bump reauth_required_at on all rows
--                whose merged_into points at p_canonical_user_key (one hop).
--
--  W12 (CA2 W5): stir_ops_reactivation_enqueue concurrent-invocation race
--                produced duplicate reactivation pushes per user. Fix:
--                pg_try_advisory_xact_lock gate at function entry — second
--                concurrent caller returns 0 (skip).

BEGIN;

-- 1. stir_ops_reset_quota — atomic via SELECT ... FOR UPDATE.
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
  v_before      JSONB;
  v_after       JSONB;
  v_now_period  DATE;
BEGIN
  IF NOT (public.is_admin() OR COALESCE(auth.jwt() ->> 'role', '') = 'service_role') THEN
    RAISE EXCEPTION 'not admin' USING ERRCODE = '42501';
  END IF;

  -- Lock the row before snapshotting + updating (W34 fix). A concurrent
  -- increment will wait for this transaction to commit; we hold the lock
  -- across both statements, so v_before reflects the same state the
  -- UPDATE sees.
  SELECT to_jsonb(uc) INTO v_before
  FROM usage_counters uc
  WHERE uc.canonical_user_key = p_canonical_user_key
    AND uc.feature_key = p_feature_key
    AND uc.period_start = (
      SELECT MAX(period_start) FROM usage_counters
      WHERE canonical_user_key = p_canonical_user_key
        AND feature_key = p_feature_key
    )
  FOR UPDATE;

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
  'Zeroes used_count for the current period (cap_count preserved). Uses SELECT ... FOR UPDATE to snapshot + update atomically — the audit before/after pair always reflects the same row state (W34 fix). Returns { before, after } for audit. Admin-gated.';

-- 2. stir_ops_force_reauth — cascade to merged siblings (W39).
CREATE OR REPLACE FUNCTION public.stir_ops_force_reauth(
  p_canonical_user_key TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_before          JSONB;
  v_after           JSONB;
  v_merged_count    INTEGER;
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

  -- Primary target.
  UPDATE app_users
     SET reauth_required_at = now()
   WHERE canonical_user_key = p_canonical_user_key
   RETURNING to_jsonb(app_users.*) INTO v_after;

  -- W39: cascade to any merged sibling rows (install → ck). An iOS JWT
  -- issued before the merge still carries the install-keyed sub;
  -- without this, the reauth check would pass on that JWT because the
  -- install row's reauth_required_at is NULL. _shared/auth.ts also
  -- does a merged_into follow on verify, but bumping both rows keeps
  -- the DB state self-consistent for the direct-lookup path.
  UPDATE app_users
     SET reauth_required_at = now()
   WHERE merged_into = p_canonical_user_key
     AND status = 'merged';

  GET DIAGNOSTICS v_merged_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'before', v_before,
    'after', v_after,
    'merged_siblings_bumped', v_merged_count
  );
END $$;

COMMENT ON FUNCTION public.stir_ops_force_reauth(TEXT) IS
  'Sets reauth_required_at = now() on the target user + any merged_into siblings. Forces SIWA re-flow on every JWT issued before the bump via the _shared/auth.ts reauth gate. Admin-gated. (W39 review fix — merged chain cascade.)';

-- 3. stir_ops_reactivation_enqueue — advisory lock (W12).
--    Preserves the original (INTEGER, INTEGER) signature from migration
--    20260423000009; body adds a pg_try_advisory_xact_lock gate at the top
--    + filters on device_installations.notification_prefs_json per the
--    original schema (the function reads prefs from the install row, not
--    the user row).
CREATE OR REPLACE FUNCTION public.stir_ops_reactivation_enqueue(
  p_inactive_days   INTEGER DEFAULT 14,
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
  -- W12: advisory lock. Second concurrent caller (manual admin trigger
  -- overlapping the 18:00 cron, DST rollover double-fire) skips silently.
  -- xact-scoped lock releases on commit; no cleanup.
  IF NOT pg_try_advisory_xact_lock(hashtext('stir_ops_reactivation_enqueue')) THEN
    RAISE NOTICE 'stir_ops_reactivation_enqueue: advisory lock held, skipping this invocation';
    RETURN 0;
  END IF;

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
  'Cron-invoked daily. Seeds notification_jobs push_send rows for inactive users (14-21 days, active, push-enabled, not-recently-nudged). Returns insert count. Advisory lock (W12) prevents concurrent double-enqueue.';

COMMIT;
