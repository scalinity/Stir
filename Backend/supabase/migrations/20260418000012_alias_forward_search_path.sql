-- Pin search_path on stir_alias_forward.
--
-- Supabase's database linter (0011_function_search_path_mutable) flagged
-- the alias-forward function for having a role-mutable search_path. With
-- the search_path unset, a malicious schema earlier in the resolution
-- order could shadow our public.usage_counters / public.app_users tables
-- and trick the function into operating on attacker-controlled rows.
--
-- Fixed by setting `search_path = public, pg_temp` directly on the function
-- (per Supabase's recommended remediation). pg_temp is included so server-
-- side temp tables continue to work; public is the only application schema.
--
-- Idempotent: ALTER FUNCTION ... SET applies cleanly on re-run.

ALTER FUNCTION public.stir_alias_forward(TEXT, TEXT)
  SET search_path = public, pg_temp;
