-- Stir operational schema — fix auth_rls_initplan WARN on user-scoped policies
--
-- Discovered via get_advisors during the step-3 deploy. Same-session fix
-- per CLAUDE.md §"Deploy workflow — local and prod in lockstep".
--
-- Issue: every auth.jwt() call in an RLS policy re-parses the JWT per row.
-- At our scale it's invisible; at dashboard-aggregation scale it's a
-- multiplier on row count. Fix is to wrap in `(SELECT auth.jwt() ...)`
-- so the optimizer hoists evaluation to init-plan (once per query).
-- See: https://supabase.com/docs/guides/database/postgres/row-level-security#call-functions-with-select
--
-- Safe to replace in place: same logical semantics, same USING clause
-- reference to the row's canonical_user_key.

DROP POLICY IF EXISTS usage_counters_own_row_select ON usage_counters;
CREATE POLICY usage_counters_own_row_select ON usage_counters
  FOR SELECT
  TO authenticated
  USING ((SELECT auth.jwt() ->> 'canonical_user_key') = canonical_user_key);

DROP POLICY IF EXISTS entitlement_snapshots_own_row_select ON entitlement_snapshots;
CREATE POLICY entitlement_snapshots_own_row_select ON entitlement_snapshots
  FOR SELECT
  TO authenticated
  USING ((SELECT auth.jwt() ->> 'canonical_user_key') = canonical_user_key);

DROP POLICY IF EXISTS ai_request_log_own_row_select ON ai_request_log;
CREATE POLICY ai_request_log_own_row_select ON ai_request_log
  FOR SELECT
  TO authenticated
  USING ((SELECT auth.jwt() ->> 'canonical_user_key') = canonical_user_key);

DROP POLICY IF EXISTS device_installations_own_row_select ON device_installations;
CREATE POLICY device_installations_own_row_select ON device_installations
  FOR SELECT
  TO authenticated
  USING ((SELECT auth.jwt() ->> 'canonical_user_key') = canonical_user_key);

COMMENT ON POLICY usage_counters_own_row_select        ON usage_counters        IS 'User can SELECT own row. (SELECT auth.jwt()) form lets optimizer hoist JWT parse to init-plan.';
COMMENT ON POLICY entitlement_snapshots_own_row_select ON entitlement_snapshots IS 'User can SELECT own row. (SELECT auth.jwt()) form lets optimizer hoist JWT parse to init-plan.';
COMMENT ON POLICY ai_request_log_own_row_select        ON ai_request_log        IS 'User can SELECT own row. (SELECT auth.jwt()) form lets optimizer hoist JWT parse to init-plan.';
COMMENT ON POLICY device_installations_own_row_select  ON device_installations  IS 'User can SELECT own row. (SELECT auth.jwt()) form lets optimizer hoist JWT parse to init-plan.';
