-- Fix: plpgsql OUT parameters named `used_count` / `cap_count` collided
-- with the usage_counters column of the same name inside the UPDATE …
-- WHERE used_count < cap_count clause. Migration 18 shipped without the
-- `#variable_conflict use_column` directive and broke on first call.
--
-- Redefinition only — same signature, same return shape, same contract.
-- CREATE OR REPLACE drops the old body.
--
-- Prod had 18 applied before local caught the bug; this migration is
-- the corrective follow-up so the migration history on both sides
-- ends up at the same state.

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
END;
$$;

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
