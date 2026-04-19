-- Stir operational schema — stir_alias_forward idempotent early-return
--
-- Context: two devices launching concurrently for the same identity flip
-- (install:A + ck:X appearing for the first time) can both reach the
-- alias-forward branch in `/v1/session/bootstrap`. The first caller
-- completes the merge; the second finds the install row with
-- status='merged' and merged_into=p_ck_key and runs the full SQL function
-- body anyway — inserting zero rows (usage_counters for install are gone),
-- deleting zero rows, updating last_seen_at on the ck row. Correct result,
-- wasted work and confusing log lines.
--
-- Fix: early-return when the install row is already merged to the target
-- ck key. Preserves the existing `install_row_absent` contract (both
-- signal "no work needed") and is safe to re-run against the old function
-- body because the early-return path is strictly a subset of the existing
-- logic.

CREATE OR REPLACE FUNCTION stir_alias_forward(
  p_install_key TEXT,
  p_ck_key      TEXT
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_install_exists        BOOLEAN;
  v_install_status        app_user_status;
  v_install_merged_into   TEXT;
  v_ck_exists             BOOLEAN;
  v_entitlement_discarded BOOLEAN := FALSE;
  v_ai_log_rewritten      INT     := 0;
  v_device_rewritten      INT     := 0;
  v_usage_merged          INT     := 0;
BEGIN
  IF p_install_key IS NULL OR p_ck_key IS NULL THEN
    RAISE EXCEPTION 'stir_alias_forward: both keys required (install=%, ck=%)',
      p_install_key, p_ck_key;
  END IF;
  IF p_install_key = p_ck_key THEN
    RAISE EXCEPTION 'stir_alias_forward: install_key and ck_key are identical (%)', p_install_key;
  END IF;

  SELECT status, merged_into
    INTO v_install_status, v_install_merged_into
    FROM app_users
   WHERE canonical_user_key = p_install_key;
  v_install_exists := FOUND;

  SELECT EXISTS(
    SELECT 1 FROM app_users WHERE canonical_user_key = p_ck_key
  ) INTO v_ck_exists;

  IF NOT v_install_exists THEN
    RETURN jsonb_build_object(
      'alias_performed',           FALSE,
      'reason',                    'install_row_absent',
      'usage_rows_merged',         0,
      'entitlement_row_discarded', FALSE,
      'ai_log_rows_rewritten',     0,
      'device_rows_rewritten',     0
    );
  END IF;

  -- Idempotent early-return: install is already merged to this exact target.
  -- Second concurrent caller, re-deliver of a webhook, or retry after partial
  -- success — all safe to short-circuit since the merge already landed.
  IF v_install_status = 'merged' AND v_install_merged_into = p_ck_key THEN
    RETURN jsonb_build_object(
      'alias_performed',           FALSE,
      'reason',                    'already_merged_to_target',
      'usage_rows_merged',         0,
      'entitlement_row_discarded', FALSE,
      'ai_log_rows_rewritten',     0,
      'device_rows_rewritten',     0
    );
  END IF;

  IF NOT v_ck_exists THEN
    RAISE EXCEPTION
      'stir_alias_forward: ck_key % does not exist in app_users (caller must INSERT first)',
      p_ck_key;
  END IF;

  -- 1. Sum usage_counters per (period_start, feature_key) onto the ck row.
  WITH merged AS (
    INSERT INTO usage_counters (
      canonical_user_key, period_start, feature_key,
      used_count, cap_count, tier_at_snapshot,
      created_at, updated_at
    )
    SELECT
      p_ck_key, period_start, feature_key,
      used_count, cap_count, tier_at_snapshot,
      created_at, now()
    FROM usage_counters
    WHERE canonical_user_key = p_install_key
    ON CONFLICT (canonical_user_key, period_start, feature_key) DO UPDATE SET
      used_count = usage_counters.used_count + EXCLUDED.used_count,
      cap_count = CASE
        WHEN usage_counters.created_at >= EXCLUDED.created_at THEN usage_counters.cap_count
        ELSE EXCLUDED.cap_count
      END,
      tier_at_snapshot = CASE
        WHEN usage_counters.created_at >= EXCLUDED.created_at THEN usage_counters.tier_at_snapshot
        ELSE EXCLUDED.tier_at_snapshot
      END,
      updated_at = now()
    RETURNING 1
  )
  SELECT count(*) INTO v_usage_merged FROM merged;

  DELETE FROM usage_counters WHERE canonical_user_key = p_install_key;

  IF EXISTS (
    SELECT 1 FROM entitlement_snapshots WHERE canonical_user_key = p_install_key
  ) THEN
    v_entitlement_discarded := TRUE;
  END IF;
  DELETE FROM entitlement_snapshots WHERE canonical_user_key = p_install_key;

  UPDATE ai_request_log
     SET canonical_user_key = p_ck_key
   WHERE canonical_user_key = p_install_key;
  GET DIAGNOSTICS v_ai_log_rewritten = ROW_COUNT;

  UPDATE device_installations
     SET canonical_user_key = p_ck_key
   WHERE canonical_user_key = p_install_key;
  GET DIAGNOSTICS v_device_rewritten = ROW_COUNT;

  UPDATE app_users
     SET merged_into = p_ck_key,
         status      = 'merged'
   WHERE canonical_user_key = p_install_key;

  UPDATE app_users
     SET last_seen_at = now()
   WHERE canonical_user_key = p_ck_key;

  RETURN jsonb_build_object(
    'alias_performed',           TRUE,
    'usage_rows_merged',         v_usage_merged,
    'entitlement_row_discarded', v_entitlement_discarded,
    'ai_log_rows_rewritten',     v_ai_log_rewritten,
    'device_rows_rewritten',     v_device_rewritten
  );
END;
$$;

-- search_path pinning from migration 12 carries forward across CREATE OR
-- REPLACE; re-apply explicitly in case this migration runs before 12 in a
-- fresh environment.
ALTER FUNCTION public.stir_alias_forward(TEXT, TEXT)
  SET search_path = public, pg_temp;

COMMENT ON FUNCTION stir_alias_forward(TEXT, TEXT) IS
  'Atomically merge install:<id> identity forward to ck:<record>. Idempotent: early-returns when install already merged to target. See migration 11 header for per-table rules.';
