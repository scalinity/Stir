-- Stir operational schema — RevenueCat webhook RPCs.
--
-- Two functions land together:
--
--   stir_process_webhook_event
--     Transactional "check idempotency + upsert entitlement" operation.
--     Handler calls this for upsert_entitlement actions from the event
--     resolver. Fire-and-return: either the event is new (and the
--     entitlement_snapshots row gets written) OR it's a duplicate (no-op,
--     status='duplicate' in the return value).
--
--   stir_transfer_entitlement
--     TRANSFER event: reassign entitlement_snapshots.canonical_user_key
--     from → to. Rare; also ensures app_users row exists for the new
--     key. SUBSCRIBER_ALIAS reuses stir_alias_forward; TRANSFER doesn't
--     carry install-scoped data, so a full alias-forward merge is
--     overkill.
--
-- Both are plpgsql (matching stir_alias_forward) and require service_role.
-- REVOKE EXECUTE is applied at the end of this migration to match the
-- pattern from migration 20260418000020.

-- ---------------------------------------------------------------------------
-- stir_process_webhook_event
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stir_process_webhook_event(
  p_event_id            TEXT,
  p_event_type          TEXT,
  p_canonical_user_key  TEXT,
  p_tier                user_tier,
  p_billing_state       billing_state,
  p_is_trial            BOOLEAN,
  p_expires_at          TIMESTAMPTZ,
  p_raw_payload         JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_inserted_event BOOLEAN := FALSE;
  v_app_user_existed BOOLEAN;
BEGIN
  IF p_event_id IS NULL OR p_canonical_user_key IS NULL THEN
    RAISE EXCEPTION 'stir_process_webhook_event: event_id + canonical_user_key required (event_id=%, key=%)',
      p_event_id, p_canonical_user_key;
  END IF;

  -- Idempotency gate. ON CONFLICT DO NOTHING returns the original row
  -- (INSERT-path) or no row (duplicate). RETURNING combined with
  -- `INTO … NOT FOUND` gives us a clean boolean.
  WITH ins AS (
    INSERT INTO processed_webhook_events (event_id, event_type)
    VALUES (p_event_id, p_event_type)
    ON CONFLICT (event_id) DO NOTHING
    RETURNING 1
  )
  SELECT EXISTS(SELECT 1 FROM ins) INTO v_inserted_event;

  IF NOT v_inserted_event THEN
    -- Already processed — short-circuit. Caller returns 200 immediately.
    RETURN jsonb_build_object('status', 'duplicate');
  END IF;

  -- Ensure the app_users row exists. Normal case: bootstrap already
  -- created it. Edge case: webhook fires for a user who never bootstrapped
  -- (RC test event, or a race where purchase completed before the first
  -- bootstrap returned). Creating a minimal row here keeps the FK happy
  -- and lets future bootstrap runs find + update the record.
  SELECT EXISTS(
    SELECT 1 FROM app_users WHERE canonical_user_key = p_canonical_user_key
  ) INTO v_app_user_existed;

  IF NOT v_app_user_existed THEN
    INSERT INTO app_users (
      canonical_user_key,
      source_type,
      revenuecat_app_user_id,
      status
    )
    VALUES (
      p_canonical_user_key,
      CASE
        WHEN p_canonical_user_key LIKE 'ck:%'      THEN 'cloudkit'::user_source
        WHEN p_canonical_user_key LIKE 'install:%' THEN 'install'::user_source
        ELSE 'install'::user_source
      END,
      p_canonical_user_key,
      'active'
    )
    ON CONFLICT (canonical_user_key) DO NOTHING;
  END IF;

  -- Upsert the entitlement row.
  INSERT INTO entitlement_snapshots (
    canonical_user_key,
    tier,
    is_trial,
    expires_at,
    billing_state,
    raw_webhook_payload,
    updated_at
  )
  VALUES (
    p_canonical_user_key,
    p_tier,
    p_is_trial,
    p_expires_at,
    p_billing_state,
    p_raw_payload,
    now()
  )
  ON CONFLICT (canonical_user_key) DO UPDATE SET
    tier                = EXCLUDED.tier,
    is_trial            = EXCLUDED.is_trial,
    expires_at          = EXCLUDED.expires_at,
    billing_state       = EXCLUDED.billing_state,
    raw_webhook_payload = EXCLUDED.raw_webhook_payload,
    updated_at          = now();

  RETURN jsonb_build_object(
    'status', 'accepted',
    'app_user_created', NOT v_app_user_existed
  );
END;
$$;

COMMENT ON FUNCTION stir_process_webhook_event(
  TEXT, TEXT, TEXT, user_tier, billing_state, BOOLEAN, TIMESTAMPTZ, JSONB
) IS 'Atomic idempotent webhook-event application. Service-role only.';

-- ---------------------------------------------------------------------------
-- stir_transfer_entitlement
-- ---------------------------------------------------------------------------
--
-- TRANSFER event: subscription was transferred between Apple IDs. Reassign
-- entitlement from `p_from` → `p_to`. This is NOT a full identity merge
-- (SUBSCRIBER_ALIAS handles that via stir_alias_forward) — a TRANSFER
-- doesn't carry install-scoped usage history; it's purely a subscription
-- reassignment on the RC side. We:
--
--   1. Ensure `p_to` app_users row exists.
--   2. Move entitlement_snapshots row from p_from → p_to (discard p_from
--      row if both exist).
--
-- Idempotency is enforced at the caller (via processed_webhook_events
-- before calling this). Running this function twice for the same transfer
-- is still safe — the second run finds no p_from entitlement row and
-- no-ops.

CREATE OR REPLACE FUNCTION stir_transfer_entitlement(
  p_event_id            TEXT,
  p_event_type          TEXT,
  p_from                TEXT,
  p_to                  TEXT,
  p_raw_payload         JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
  v_inserted_event BOOLEAN := FALSE;
  v_from_row       entitlement_snapshots%ROWTYPE;
  v_rows_moved     INT := 0;
BEGIN
  IF p_from IS NULL OR p_to IS NULL THEN
    RAISE EXCEPTION 'stir_transfer_entitlement: both from + to required (from=%, to=%)',
      p_from, p_to;
  END IF;
  IF p_from = p_to THEN
    RAISE EXCEPTION 'stir_transfer_entitlement: from and to identical (%)', p_from;
  END IF;

  -- Idempotency gate.
  WITH ins AS (
    INSERT INTO processed_webhook_events (event_id, event_type)
    VALUES (p_event_id, p_event_type)
    ON CONFLICT (event_id) DO NOTHING
    RETURNING 1
  )
  SELECT EXISTS(SELECT 1 FROM ins) INTO v_inserted_event;

  IF NOT v_inserted_event THEN
    RETURN jsonb_build_object('status', 'duplicate');
  END IF;

  -- Ensure target app_users row exists.
  INSERT INTO app_users (
    canonical_user_key, source_type, revenuecat_app_user_id, status
  )
  VALUES (
    p_to,
    CASE WHEN p_to LIKE 'ck:%' THEN 'cloudkit'::user_source ELSE 'install'::user_source END,
    p_to,
    'active'
  )
  ON CONFLICT (canonical_user_key) DO NOTHING;

  -- Load the source entitlement (if any) so we can carry its tier /
  -- billing_state forward to the new canonical key.
  SELECT * INTO v_from_row
    FROM entitlement_snapshots
   WHERE canonical_user_key = p_from;

  IF NOT FOUND THEN
    -- No source entitlement to move. Log and no-op.
    RETURN jsonb_build_object(
      'status',       'accepted',
      'rows_moved',   0,
      'reason',       'from_entitlement_absent'
    );
  END IF;

  -- Upsert the target row with the source's tier + billing state, then
  -- delete the source row. Raw payload on the target gets the TRANSFER
  -- event's payload for audit.
  INSERT INTO entitlement_snapshots (
    canonical_user_key,
    tier,
    is_trial,
    expires_at,
    billing_state,
    raw_webhook_payload,
    updated_at
  )
  VALUES (
    p_to,
    v_from_row.tier,
    v_from_row.is_trial,
    v_from_row.expires_at,
    v_from_row.billing_state,
    p_raw_payload,
    now()
  )
  ON CONFLICT (canonical_user_key) DO UPDATE SET
    tier                = EXCLUDED.tier,
    is_trial            = EXCLUDED.is_trial,
    expires_at          = EXCLUDED.expires_at,
    billing_state       = EXCLUDED.billing_state,
    raw_webhook_payload = EXCLUDED.raw_webhook_payload,
    updated_at          = now();

  DELETE FROM entitlement_snapshots WHERE canonical_user_key = p_from;
  GET DIAGNOSTICS v_rows_moved = ROW_COUNT;

  RETURN jsonb_build_object(
    'status',     'accepted',
    'rows_moved', v_rows_moved
  );
END;
$$;

COMMENT ON FUNCTION stir_transfer_entitlement(TEXT, TEXT, TEXT, TEXT, JSONB) IS
  'TRANSFER webhook handler: reassign entitlement from → to. Service-role only.';

-- ---------------------------------------------------------------------------
-- Grants (REVOKE from anon/authenticated; GRANT to service_role only)
-- ---------------------------------------------------------------------------

REVOKE EXECUTE ON FUNCTION stir_process_webhook_event(
  TEXT, TEXT, TEXT, user_tier, billing_state, BOOLEAN, TIMESTAMPTZ, JSONB
) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION stir_process_webhook_event(
  TEXT, TEXT, TEXT, user_tier, billing_state, BOOLEAN, TIMESTAMPTZ, JSONB
) TO service_role;

REVOKE EXECUTE ON FUNCTION stir_transfer_entitlement(TEXT, TEXT, TEXT, TEXT, JSONB)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION stir_transfer_entitlement(TEXT, TEXT, TEXT, TEXT, JSONB)
  TO service_role;
