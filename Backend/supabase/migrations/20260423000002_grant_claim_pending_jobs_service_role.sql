-- Explicit GRANT EXECUTE to service_role on stir_claim_pending_jobs.
--
-- CA2-5: the initial migration revoked from PUBLIC/authenticated/anon
-- but never explicitly GRANTed to service_role. Works today because
-- service_role inherits certain privileges under Supabase's default
-- role setup, but breaks loudly on tightened-permissions environments
-- (e.g. once roles are audit-scoped).
--
-- Idempotent via GRANT EXECUTE which no-ops on re-run.

GRANT EXECUTE ON FUNCTION stir_claim_pending_jobs(INTEGER) TO service_role;

COMMENT ON FUNCTION stir_claim_pending_jobs(INTEGER) IS
  'Atomic claim of up to N pending notification_jobs. Flips state to processing + increments attempt_count. Returns pre-flip snapshot. service-role only. Explicitly granted 2026-04-23 (CA2-5).';
