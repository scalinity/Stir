-- Stir operational schema — stir_alias_forward: serialize concurrent merges
-- via a Postgres advisory lock.
--
-- CA2 reliability audit race: `stir_alias_forward` can be invoked concurrently
-- for the same (install, ck) pair from two paths:
--
--   Path A: /v1/session/bootstrap calls it synchronously at launch when
--           an install-keyed row gains CloudKit availability.
--   Path B: stir_process_alias_webhook invokes it in response to RC's
--           SUBSCRIBER_ALIAS event (fired moments later by Purchases.logIn).
--
-- Both serialize on the idempotency table for the DISTINCT event_ids they
-- each write (bootstrap doesn't write to processed_webhook_events at all).
-- Without a cross-path lock, the two concurrent calls race on:
--
--   - usage_counters rows for the install key (the merged-INSERT +
--     subsequent DELETE form a read-modify-write where a second caller
--     landing between them could see phantom double-merged state).
--   - The entitlement_snapshots promote-vs-discard decision: both callers
--     may observe identical "ck has no row" pre-images and both attempt
--     to promote, hitting a UNIQUE violation on canonical_user_key.
--
-- Fix: acquire a transaction-scoped advisory lock keyed on the install_key
-- hash at the top of the function. `pg_advisory_xact_lock` blocks a
-- concurrent caller on the same key until the first transaction commits;
-- once released, the second call's app_users pre-check will already
-- observe `merged_into` set and return 'install_row_absent' (really
-- "install_row_already_merged"). Idempotent by construction.
--
-- The lock is CONDITIONAL: we only acquire if BOTH pre-check booleans
-- evaluated — that way an aborted pre-check (missing input validation)
-- never takes the lock pointlessly.
--
-- Advisory lock key: `hashtext(p_install_key)` produces a stable int4.
-- Postgres pg_advisory_xact_lock(int4, int4) takes two; we use a magic
-- constant for the first slot ('stir_alias' = 42 here) and the install
-- key hash for the second so the lock namespace is isolated from other
-- advisory locks the service might acquire.

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

  -- Serialize concurrent merges on the same install_key. Released at
  -- transaction commit. See migration COMMENT block above for rationale.
  PERFORM pg_advisory_xact_lock(42, hashtext(p_install_key));

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

  -- If the install row is already marked merged, we're the loser of a
  -- prior race. Return idempotently.
  IF EXISTS (
    SELECT 1 FROM app_users
     WHERE canonical_user_key = p_install_key
       AND status = 'merged'
  ) THEN
    RETURN jsonb_build_object(
      'alias_performed',            FALSE,
      'reason',                     'install_row_already_merged',
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

  -- 3. entitlement_snapshots — unchanged from migration 4:
  IF EXISTS (SELECT 1 FROM entitlement_snapshots WHERE canonical_user_key = p_ck_key) THEN
    IF EXISTS (SELECT 1 FROM entitlement_snapshots WHERE canonical_user_key = p_install_key) THEN
      v_entitlement_discarded := TRUE;
    END IF;
    DELETE FROM entitlement_snapshots WHERE canonical_user_key = p_install_key;
  ELSIF EXISTS (SELECT 1 FROM entitlement_snapshots WHERE canonical_user_key = p_install_key) THEN
    UPDATE entitlement_snapshots
       SET canonical_user_key = p_ck_key,
           updated_at         = now()
     WHERE canonical_user_key = p_install_key;
    v_entitlement_promoted := TRUE;
  END IF;

  -- 4. ai_request_log: rewrite install → ck.
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

-- Re-grant (CREATE OR REPLACE preserves grants, but an explicit repeat
-- is cheap belt-and-suspenders).
REVOKE EXECUTE ON FUNCTION stir_alias_forward(TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION stir_alias_forward(TEXT, TEXT)
  TO service_role;

-- Re-pin search_path in case a prior ALTER FUNCTION config was dropped
-- by the CREATE OR REPLACE above (PG docs: SET configs are preserved on
-- replace of same signature, but only when not explicitly re-specified
-- in the CREATE body). This is idempotent.
ALTER FUNCTION public.stir_alias_forward(TEXT, TEXT)
  SET search_path = public, pg_temp;

COMMENT ON FUNCTION stir_alias_forward(TEXT, TEXT) IS
  'Atomically merge install:<id> → ck:<record>. Serialized on install_key via pg_advisory_xact_lock. Idempotent: returns install_row_already_merged if a prior call already moved the install row. See migration 20260419000012.';
