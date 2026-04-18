-- Stir operational schema — Row-Level Security policies
-- Every operational table has RLS enabled. Policy semantics:
--
-- USER-SCOPED tables (usage_counters, entitlement_snapshots, ai_request_log,
-- device_installations): `authenticated` role can SELECT only rows where
-- the JWT's canonical_user_key claim matches the row's canonical_user_key.
-- No INSERT/UPDATE/DELETE policies for `authenticated` — all writes happen
-- through Edge Functions using the service-role client which bypasses RLS.
--
-- OPS-ONLY tables (app_users, feature_flags, prompt_versions): no policies
-- for `authenticated`. Direct PostgREST access from an authenticated client
-- returns empty. Only service-role can read/write these.
--
-- auth.jwt() comes from Supabase's auth helper schema and returns JSONB
-- extracted from the validated JWT claims. Our custom JWT (HS256 signed
-- with SUPABASE_JWT_SECRET, role: "authenticated") is accepted natively.
--
-- Naming: `<table>_<subject>_<operation>` for clarity in pg_policies dumps.

-- ---------------------------------------------------------------------------
-- User-scoped tables
-- ---------------------------------------------------------------------------

ALTER TABLE usage_counters ENABLE ROW LEVEL SECURITY;
CREATE POLICY usage_counters_own_row_select ON usage_counters
  FOR SELECT
  TO authenticated
  USING ((auth.jwt() ->> 'canonical_user_key') = canonical_user_key);

ALTER TABLE entitlement_snapshots ENABLE ROW LEVEL SECURITY;
CREATE POLICY entitlement_snapshots_own_row_select ON entitlement_snapshots
  FOR SELECT
  TO authenticated
  USING ((auth.jwt() ->> 'canonical_user_key') = canonical_user_key);

ALTER TABLE ai_request_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY ai_request_log_own_row_select ON ai_request_log
  FOR SELECT
  TO authenticated
  USING ((auth.jwt() ->> 'canonical_user_key') = canonical_user_key);

ALTER TABLE device_installations ENABLE ROW LEVEL SECURITY;
CREATE POLICY device_installations_own_row_select ON device_installations
  FOR SELECT
  TO authenticated
  USING ((auth.jwt() ->> 'canonical_user_key') = canonical_user_key);

-- ---------------------------------------------------------------------------
-- Ops-only tables: RLS enabled, no `authenticated` policies = default deny
-- ---------------------------------------------------------------------------

ALTER TABLE app_users       ENABLE ROW LEVEL SECURITY;
ALTER TABLE feature_flags   ENABLE ROW LEVEL SECURITY;
ALTER TABLE prompt_versions ENABLE ROW LEVEL SECURITY;

-- Intentionally no CREATE POLICY statements for the three above. Service
-- role bypasses RLS natively; authenticated clients see empty result sets
-- when attempting direct PostgREST access. RLS tests assert this behavior.

COMMENT ON POLICY usage_counters_own_row_select         ON usage_counters         IS 'Users can only SELECT their own counter rows. Writes via service-role only.';
COMMENT ON POLICY entitlement_snapshots_own_row_select  ON entitlement_snapshots  IS 'Users can only SELECT their own entitlement. RevenueCat webhook writes via service-role.';
COMMENT ON POLICY ai_request_log_own_row_select         ON ai_request_log         IS 'Users can only SELECT their own AI request history. Writes via service-role.';
COMMENT ON POLICY device_installations_own_row_select   ON device_installations   IS 'Users can only SELECT their own device installations. Writes via service-role.';
