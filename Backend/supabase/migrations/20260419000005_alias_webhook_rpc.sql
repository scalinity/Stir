-- Stir operational schema — stir_process_alias_webhook RPC.
--
-- Fixes the SUBSCRIBER_ALIAS idempotency TOCTOU that the step-5 review
-- surfaced: the handler's `alias` branch was inserting into
-- `processed_webhook_events` from JS, then calling `stir_alias_forward`
-- separately. If the merge RPC threw after the idempotency row was
-- written, RC would retry, the idempotency check would short-circuit
-- as `duplicate`, and the alias would be silently lost.
--
-- This wrapper RPC does both operations in one plpgsql transaction, the
-- same pattern `stir_process_webhook_event` uses for upserts:
--   1. INSERT into processed_webhook_events (or detect duplicate).
--   2. Ensure both app_users rows exist (materialize if absent).
--   3. Call stir_alias_forward.
--
-- Service-role only. Returns the alias-forward JSONB plus a `status`
-- discriminant so the handler can write the webhook_log row.

CREATE OR REPLACE FUNCTION stir_process_alias_webhook(
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
  v_from_source    user_source;
  v_to_source      user_source;
  v_alias_result   JSONB;
BEGIN
  IF p_event_id IS NULL OR p_from IS NULL OR p_to IS NULL THEN
    RAISE EXCEPTION
      'stir_process_alias_webhook: event_id + from + to required (event_id=%, from=%, to=%)',
      p_event_id, p_from, p_to;
  END IF;
  IF p_from = p_to THEN
    RAISE EXCEPTION 'stir_process_alias_webhook: from and to identical (%)', p_from;
  END IF;

  -- 1. Idempotency gate.
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

  -- 2. Ensure both app_users rows exist. Source derived from key prefix.
  --    stir_alias_forward raises if either is missing; we materialize
  --    here so the RPC proceeds cleanly in the rare edge where a webhook
  --    precedes the user's first bootstrap.
  v_from_source := CASE
    WHEN p_from LIKE 'ck:%'      THEN 'cloudkit'::user_source
    WHEN p_from LIKE 'install:%' THEN 'install'::user_source
    ELSE 'install'::user_source
  END;
  v_to_source := CASE
    WHEN p_to LIKE 'ck:%'      THEN 'cloudkit'::user_source
    WHEN p_to LIKE 'install:%' THEN 'install'::user_source
    ELSE 'install'::user_source
  END;

  INSERT INTO app_users (canonical_user_key, source_type, revenuecat_app_user_id, status)
  VALUES (p_from, v_from_source, p_from, 'active')
  ON CONFLICT (canonical_user_key) DO NOTHING;

  INSERT INTO app_users (canonical_user_key, source_type, revenuecat_app_user_id, status)
  VALUES (p_to, v_to_source, p_to, 'active')
  ON CONFLICT (canonical_user_key) DO NOTHING;

  -- 3. Perform the alias-forward merge.
  v_alias_result := stir_alias_forward(p_from, p_to);

  -- Attach the raw payload as an audit breadcrumb on the winning row's
  -- entitlement_snapshots, if one exists. Non-essential; ignore if no row.
  UPDATE entitlement_snapshots
     SET raw_webhook_payload = p_raw_payload,
         updated_at          = now()
   WHERE canonical_user_key = p_to;

  RETURN jsonb_build_object(
    'status',       'accepted',
    'alias_result', v_alias_result
  );
END;
$$;

COMMENT ON FUNCTION stir_process_alias_webhook(TEXT, TEXT, TEXT, TEXT, JSONB) IS
  'Atomic SUBSCRIBER_ALIAS webhook handler: idempotency gate + ensure both app_users rows + stir_alias_forward, all in one transaction. Service-role only.';

-- Grants: service_role only.
REVOKE EXECUTE ON FUNCTION stir_process_alias_webhook(TEXT, TEXT, TEXT, TEXT, JSONB)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION stir_process_alias_webhook(TEXT, TEXT, TEXT, TEXT, JSONB)
  TO service_role;

-- Also add the matching REVOKE/GRANT block for stir_alias_forward that
-- migration 20260419000004 omitted (the CREATE OR REPLACE preserves the
-- grants from migration 20, so this is belt-and-suspenders for any future
-- signature change).
REVOKE EXECUTE ON FUNCTION stir_alias_forward(TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION stir_alias_forward(TEXT, TEXT)
  TO service_role;
