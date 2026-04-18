-- Stir operational schema — stir_alias_forward(p_install_key, p_ck_key)
--
-- Transactional alias-forward called by /v1/session/bootstrap when a new
-- ck:<record> row wins over an existing install:<id> row for the same
-- installation. Function body runs as a single implicit transaction so
-- the per-table rules land atomically:
--
--   1. usage_counters: sum used_count per (period_start, feature_key)
--      onto the ck row. Keep the newer row's cap_count + tier_at_snapshot
--      (by created_at) since that reflects the authoritative tier.
--      No cap clamping — summed rows may exceed cap, which correctly
--      keeps abuse paths locked out.
--   2. entitlement_snapshots: keep ck (RevenueCat authoritative) and
--      discard install.
--   3. ai_request_log: rewrite canonical_user_key install → ck so cost
--      history follows the winning identity.
--   4. device_installations: rewrite install → ck.
--   5. app_users (install): set merged_into = ck, status = 'merged'.
--      Never hard-deleted (audit retention per spec §11).
--   6. app_users (ck): bump last_seen_at.
--
-- Called via supabase-js rpc('stir_alias_forward', { p_install_key, p_ck_key }).
-- Returns a JSON summary of the merge for handler logs.

CREATE OR REPLACE FUNCTION stir_alias_forward(
  p_install_key TEXT,
  p_ck_key      TEXT
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_install_exists        BOOLEAN;
  v_ck_exists             BOOLEAN;
  v_entitlement_discarded BOOLEAN := FALSE;
  v_ai_log_rewritten      INT     := 0;
  v_device_rewritten      INT     := 0;
  v_usage_merged          INT     := 0;
BEGIN
  -- Input sanity checks — surface as hard errors so handler logs them.
  IF p_install_key IS NULL OR p_ck_key IS NULL THEN
    RAISE EXCEPTION 'stir_alias_forward: both keys required (install=%, ck=%)',
      p_install_key, p_ck_key;
  END IF;
  IF p_install_key = p_ck_key THEN
    RAISE EXCEPTION 'stir_alias_forward: install_key and ck_key are identical (%)', p_install_key;
  END IF;

  SELECT EXISTS(
    SELECT 1 FROM app_users WHERE canonical_user_key = p_install_key
  ) INTO v_install_exists;

  SELECT EXISTS(
    SELECT 1 FROM app_users WHERE canonical_user_key = p_ck_key
  ) INTO v_ck_exists;

  IF NOT v_install_exists THEN
    -- Nothing to alias forward; ck is either already primary or brand new.
    RETURN jsonb_build_object(
      'alias_performed',           FALSE,
      'reason',                    'install_row_absent',
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
  --    INSERT ... SELECT with ON CONFLICT gives atomic per-row merge.
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
      -- Prefer the newer row's cap_count + tier — by created_at. This
      -- handles the case where the ck row was created after a tier change
      -- (its cap reflects the new tier) vs the install row that predates it.
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

  -- 2. Delete install's usage_counters rows (now folded into ck).
  DELETE FROM usage_counters WHERE canonical_user_key = p_install_key;

  -- 3. entitlement_snapshots: keep ck (RevenueCat source of truth);
  --    delete install's row if any.
  IF EXISTS (
    SELECT 1 FROM entitlement_snapshots WHERE canonical_user_key = p_install_key
  ) THEN
    v_entitlement_discarded := TRUE;
  END IF;
  DELETE FROM entitlement_snapshots WHERE canonical_user_key = p_install_key;

  -- 4. ai_request_log: rewrite install → ck so cost attribution follows identity.
  UPDATE ai_request_log
     SET canonical_user_key = p_ck_key
   WHERE canonical_user_key = p_install_key;
  GET DIAGNOSTICS v_ai_log_rewritten = ROW_COUNT;

  -- 5. device_installations: rewrite install → ck.
  UPDATE device_installations
     SET canonical_user_key = p_ck_key
   WHERE canonical_user_key = p_install_key;
  GET DIAGNOSTICS v_device_rewritten = ROW_COUNT;

  -- 6. app_users (install): mark merged. NEVER hard-delete (audit).
  UPDATE app_users
     SET merged_into = p_ck_key,
         status      = 'merged'
   WHERE canonical_user_key = p_install_key;

  -- 7. app_users (ck): bump last_seen_at.
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

COMMENT ON FUNCTION stir_alias_forward(TEXT, TEXT) IS
  'Atomically merge install:<id> identity forward to ck:<record>. See migration header for per-table rules.';
