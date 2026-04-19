-- Stir operational schema — quota increment + decrement RPCs
--
-- Atomic UPDATE-WHERE-used<cap-RETURNING pattern for per-user metered
-- quota enforcement (dinner_solve, voice_cook_session, recipe_import).
--
-- Increment is called on the "fast path" before Gemini work begins —
-- if RATE-01, we return 429 without spending on the AI call.
--
-- Decrement is called on the "sad path" when Gemini fails AFTER the
-- counter was spent. iOS-side timeouts or mid-stream disconnects do
-- NOT trigger a refund — the work was done, charge it.
--
-- Both functions take period_start explicitly so refund scopes to the
-- exact row that was incremented, not a re-computed "current period"
-- which could be a different month if the request straddles the
-- anchor-day transition.
--
-- `#variable_conflict use_column` tells plpgsql to prefer column names
-- when an OUT parameter and a column share a name (used_count here).

-- ---------------------------------------------------------------------------
-- stir_increment_usage_counter — atomic consume-one-or-cap
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stir_increment_usage_counter(
  p_canonical_user_key TEXT,
  p_period_start       DATE,
  p_feature_key        usage_feature_key
) RETURNS TABLE(
  status     TEXT,
  used_count INTEGER,
  cap_count  INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
#variable_conflict use_column
DECLARE
  v_used INTEGER;
  v_cap  INTEGER;
BEGIN
  UPDATE usage_counters
     SET used_count = used_count + 1,
         updated_at = now()
   WHERE canonical_user_key = p_canonical_user_key
     AND period_start       = p_period_start
     AND feature_key        = p_feature_key
     AND used_count         < cap_count
  RETURNING used_count, cap_count INTO v_used, v_cap;

  IF FOUND THEN
    status := 'allowed';
    used_count := v_used;
    cap_count := v_cap;
    RETURN NEXT;
    RETURN;
  END IF;

  SELECT uc.used_count, uc.cap_count INTO v_used, v_cap
    FROM usage_counters uc
   WHERE uc.canonical_user_key = p_canonical_user_key
     AND uc.period_start       = p_period_start
     AND uc.feature_key        = p_feature_key;

  IF FOUND THEN
    status := 'capped';
    used_count := v_used;
    cap_count := v_cap;
    RETURN NEXT;
    RETURN;
  END IF;

  -- Row missing → empty result. Handler distinguishes via empty set.
END;
$$;

COMMENT ON FUNCTION stir_increment_usage_counter(TEXT, DATE, usage_feature_key) IS
  'Atomic UPDATE-WHERE-used<cap-RETURNING quota consume. Returns allowed|capped row, or empty when period row is missing.';

-- ---------------------------------------------------------------------------
-- stir_decrement_usage_counter — period-scoped refund
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stir_decrement_usage_counter(
  p_canonical_user_key TEXT,
  p_period_start       DATE,
  p_feature_key        usage_feature_key
) RETURNS TABLE(refunded BOOLEAN, used_count INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
#variable_conflict use_column
DECLARE
  v_used INTEGER;
BEGIN
  UPDATE usage_counters
     SET used_count = used_count - 1,
         updated_at = now()
   WHERE canonical_user_key = p_canonical_user_key
     AND period_start       = p_period_start
     AND feature_key        = p_feature_key
     AND used_count         > 0
  RETURNING used_count INTO v_used;

  IF FOUND THEN
    refunded := TRUE;
    used_count := v_used;
    RETURN NEXT;
  ELSE
    refunded := FALSE;
    used_count := 0;
    RETURN NEXT;
  END IF;
END;
$$;

COMMENT ON FUNCTION stir_decrement_usage_counter(TEXT, DATE, usage_feature_key) IS
  'Period-scoped quota refund. Clamps at 0. Returns refunded=false if row missing or already at 0.';
