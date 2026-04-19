-- Stir operational schema — stir_alias_forward: promote install entitlement
-- to ck when ck has no entitlement row.
--
-- BUG FIX (latent since step 1): the original stir_alias_forward always
-- DELETED install's entitlement_snapshots row, on the assumption that ck
-- would have its own entitlement (written earlier by RC webhook). In
-- practice, when a user purchases as `install:<uuid>` and then gains
-- iCloud, the flow is:
--
--   1. INITIAL_PURCHASE webhook writes entitlement on install row.
--   2. User signs into iCloud.
--   3. /v1/session/bootstrap calls stir_alias_forward(install, ck) —
--      which deleted install's entitlement. ck has no row.
--   4. iOS calls RC.logIn(ck:<record>) → RC fires SUBSCRIBER_ALIAS.
--   5. webhook handler calls stir_alias_forward again — no-op, install
--      row already gone.
--
--   End state: user has paid entitlement on RC but NOT in Stir. On next
--   bootstrap, iOS gets tier='free' and loses Premium features.
--
-- Fix: when ck has no entitlement row, PROMOTE install's row by updating
-- its canonical_user_key. When ck already has a row (RC webhook beat the
-- bootstrap alias), keep ck + discard install. "ck wins WHEN ck exists."
--
-- This is a CREATE OR REPLACE so re-applying the migration is safe.

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
  v_entitlement_promoted  BOOLEAN := FALSE;
  v_ai_log_rewritten      INT     := 0;
  v_device_rewritten      INT     := 0;
  v_usage_merged          INT     := 0;
BEGIN
  -- Input sanity checks.
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
    RETURN jsonb_build_object(
      'alias_performed',            FALSE,
      'reason',                     'install_row_absent',
      'usage_rows_merged',          0,
      'entitlement_row_discarded',  FALSE,
      'entitlement_row_promoted',   FALSE,
      'ai_log_rows_rewritten',      0,
      'device_rows_rewritten',      0
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

  -- 2. Delete install's usage_counters rows (now folded into ck).
  DELETE FROM usage_counters WHERE canonical_user_key = p_install_key;

  -- 3. entitlement_snapshots — the FIX:
  --    IF ck already has a row (RC webhook beat the bootstrap)  → keep ck, discard install ("ck wins").
  --    ELSIF install has a row and ck doesn't                    → promote install → ck (preserve entitlement).
  --    ELSE                                                       → no-op.
  IF EXISTS (SELECT 1 FROM entitlement_snapshots WHERE canonical_user_key = p_ck_key) THEN
    -- ck wins; discard install's row.
    IF EXISTS (SELECT 1 FROM entitlement_snapshots WHERE canonical_user_key = p_install_key) THEN
      v_entitlement_discarded := TRUE;
    END IF;
    DELETE FROM entitlement_snapshots WHERE canonical_user_key = p_install_key;
  ELSIF EXISTS (SELECT 1 FROM entitlement_snapshots WHERE canonical_user_key = p_install_key) THEN
    -- Promote install's entitlement to ck.
    UPDATE entitlement_snapshots
       SET canonical_user_key = p_ck_key,
           updated_at         = now()
     WHERE canonical_user_key = p_install_key;
    v_entitlement_promoted := TRUE;
  END IF;

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

  -- 6. app_users (install): mark merged. NEVER hard-delete.
  UPDATE app_users
     SET merged_into = p_ck_key,
         status      = 'merged'
   WHERE canonical_user_key = p_install_key;

  -- 7. app_users (ck): bump last_seen_at.
  UPDATE app_users
     SET last_seen_at = now()
   WHERE canonical_user_key = p_ck_key;

  RETURN jsonb_build_object(
    'alias_performed',            TRUE,
    'usage_rows_merged',          v_usage_merged,
    'entitlement_row_discarded',  v_entitlement_discarded,
    'entitlement_row_promoted',   v_entitlement_promoted,
    'ai_log_rows_rewritten',      v_ai_log_rewritten,
    'device_rows_rewritten',      v_device_rewritten
  );
END;
$$;

COMMENT ON FUNCTION stir_alias_forward(TEXT, TEXT) IS
  'Atomically merge install:<id> → ck:<record>. When ck has no entitlement row, install''s entitlement is promoted (renamed). When ck has a row, install''s is discarded ("ck wins"). See migration 20260419000004.';
