-- Pin search_path on the new webhook RPCs introduced in migrations
-- 20260419000003 (stir_process_webhook_event, stir_transfer_entitlement) and
-- 20260419000005 (stir_process_alias_webhook). These plpgsql functions run
-- under service_role; without a pinned search_path a role-owned schema
-- earlier in resolution order could shadow `public.app_users`,
-- `public.entitlement_snapshots`, `public.processed_webhook_events`, etc.,
-- and trick the RPC into reading/writing attacker-controlled rows.
--
-- Same remediation as migration 20260418000012 applied to stir_alias_forward:
-- ALTER FUNCTION ... SET search_path = public, pg_temp. pg_temp is
-- included so server-side temp tables continue to work; public is the
-- only application schema. pg_catalog is implicitly searched first by
-- Postgres regardless of this setting.
--
-- Idempotent: ALTER FUNCTION ... SET applies cleanly on re-run.
--
-- CWE-427 (Uncontrolled Search Path Element); Supabase linter rule
-- `0011_function_search_path_mutable`.

ALTER FUNCTION public.stir_process_webhook_event(
  TEXT, TEXT, TEXT, user_tier, billing_state, BOOLEAN, TIMESTAMPTZ, JSONB
) SET search_path = public, pg_temp;

ALTER FUNCTION public.stir_transfer_entitlement(TEXT, TEXT, TEXT, TEXT, JSONB)
  SET search_path = public, pg_temp;

ALTER FUNCTION public.stir_process_alias_webhook(TEXT, TEXT, TEXT, TEXT, JSONB)
  SET search_path = public, pg_temp;

-- Re-assert on stir_alias_forward as well. The CREATE OR REPLACE in
-- migration 20260419000004 preserves SET configs per PG docs, but this
-- is belt-and-suspenders against a future signature change dropping the
-- pin silently.
ALTER FUNCTION public.stir_alias_forward(TEXT, TEXT)
  SET search_path = public, pg_temp;
