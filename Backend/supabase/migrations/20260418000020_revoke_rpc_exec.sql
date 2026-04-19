-- Stir operational schema — REVOKE EXECUTE on internal RPCs
--
-- SECURITY FIX (SA2-01): The custom Postgres functions introduced in steps
-- 1–3 are SECURITY DEFINER (or, in alias-forward's case, plain plpgsql) and
-- were callable by any authenticated JWT holder via PostgREST's
-- /rest/v1/rpc/<fn> surface. PostgreSQL's default grant of EXECUTE to
-- PUBLIC covers the authenticated role, so a normal user could invoke
-- these RPCs with arbitrary arguments and bypass RLS (SECURITY DEFINER)
-- or manipulate another user's quota / rate-limit state.
--
-- Remediation: REVOKE EXECUTE from PUBLIC, anon, and authenticated; GRANT
-- EXECUTE to service_role only. Edge Functions use the service-role
-- client (`db.ts:createServiceClient`) which has this grant. PostgREST
-- callers carrying an authenticated JWT get a typed permission-denied
-- error instead of direct access.
--
-- Affected RPCs:
--   stir_rate_limit_check         (migration 13) — SECURITY DEFINER
--   stir_alias_forward            (migration 11) — not DEFINER but still
--                                                 callable; locking down
--                                                 to service_role future-
--                                                 proofs against a flip
--   stir_increment_usage_counter  (migration 18, 19) — SECURITY DEFINER
--   stir_decrement_usage_counter  (migration 18, 19) — SECURITY DEFINER
--
-- Idempotent: REVOKE on an already-revoked role is a no-op; GRANT is
-- upsert-style at the role level.

REVOKE EXECUTE ON FUNCTION stir_rate_limit_check(TEXT, TEXT, INTEGER, INTEGER)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION stir_rate_limit_check(TEXT, TEXT, INTEGER, INTEGER)
  TO service_role;

REVOKE EXECUTE ON FUNCTION stir_alias_forward(TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION stir_alias_forward(TEXT, TEXT)
  TO service_role;

REVOKE EXECUTE ON FUNCTION stir_increment_usage_counter(TEXT, DATE, usage_feature_key)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION stir_increment_usage_counter(TEXT, DATE, usage_feature_key)
  TO service_role;

REVOKE EXECUTE ON FUNCTION stir_decrement_usage_counter(TEXT, DATE, usage_feature_key)
  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION stir_decrement_usage_counter(TEXT, DATE, usage_feature_key)
  TO service_role;

-- Also revoke the ai_response_cache cleanup function from PUBLIC. It's
-- called only by pg_cron (which runs as postgres). No external callers.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'stir_cleanup_ai_response_cache'
  ) THEN
    EXECUTE 'REVOKE EXECUTE ON FUNCTION stir_cleanup_ai_response_cache() FROM PUBLIC, anon, authenticated';
  END IF;
END $$;

COMMENT ON FUNCTION stir_rate_limit_check(TEXT, TEXT, INTEGER, INTEGER) IS
  'Atomic sliding-window rate-limit check-and-increment. Service-role only.';
COMMENT ON FUNCTION stir_alias_forward(TEXT, TEXT) IS
  'Identity alias-forward merge. Service-role only (per-user data mutation).';
COMMENT ON FUNCTION stir_increment_usage_counter(TEXT, DATE, usage_feature_key) IS
  'Atomic per-user quota consume. Service-role only.';
COMMENT ON FUNCTION stir_decrement_usage_counter(TEXT, DATE, usage_feature_key) IS
  'Period-scoped per-user quota refund. Service-role only.';
