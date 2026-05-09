-- SCA-285 (security) + SCA-284 Cluster A — drop the legacy 4-arg
-- stir_rate_limit_check overload and re-assert SA2-01 grants on
-- the 5-arg version.
--
-- Background:
--
--   Migration 20260418000013 created the original function:
--     stir_rate_limit_check(p_scope_key TEXT, p_bucket_key TEXT,
--                           p_window_seconds INTEGER, p_max_count INTEGER)
--
--   Migration 20260418000020 (SA2-01) revoked EXECUTE from PUBLIC/anon/
--   authenticated on that 4-arg signature and granted to service_role.
--
--   Migration 20260508000010 (SCA-248 C5 from /review-5) used
--   `CREATE OR REPLACE FUNCTION` to add a new 5-arg overload:
--     stir_rate_limit_check(..., p_increment BOOLEAN DEFAULT TRUE)
--
--   That migration's commentary claimed "the 4-arg form remains as a
--   backward-compat overload via DEFAULT" — wrong. Postgres treats
--   different-arity overloads as separate `pg_proc` entries with
--   independent ACLs. The 4-arg row carried the SA2-01 lockdown; the
--   new 5-arg row was created with default `EXECUTE TO PUBLIC` (which
--   includes anon + authenticated).
--
-- Two compounding problems:
--
--   1. **PostgREST overload ambiguity (SCA-284 Cluster A).** A caller
--      passing exactly 4 args matches both signatures (the 5-arg's
--      DEFAULT covers the missing arg). PostgREST's resolution
--      algorithm returns PGRST203 "Could not choose the best
--      candidate function" — every 4-arg test caller fails.
--
--   2. **Authentication bypass on the 5-arg overload (SCA-285).**
--      A JWT-bearing client (anon or authenticated) can call the
--      5-arg form via `POST /rest/v1/rpc/stir_rate_limit_check`.
--      They can inflate counters on victims' buckets to lock them
--      out, drain their own counters via `p_increment: false`, or
--      pin advisory locks. The SA2-01 hardening intent is silently
--      violated. iOS clients don't make these calls directly so
--      live exposure is limited pre-public-launch, but the
--      privilege grant is wrong.
--
-- Fix:
--
--   1. DROP the 4-arg overload. The 5-arg form with
--      `p_increment DEFAULT TRUE` is a strict behavioral superset
--      (callers omitting the arg get the original semantics). After
--      the drop, every caller — TS wrapper, deno tests passing 4
--      args, future ad-hoc SQL — resolves unambiguously to the
--      5-arg version.
--
--   2. REVOKE EXECUTE on the 5-arg signature from PUBLIC/anon/
--      authenticated; GRANT to service_role. Mirrors the SA2-01
--      pattern from migration 20260418000020.
--
--   3. Re-assert COMMENT for security-grep visibility.
--
-- Why no caller migration is required:
--   - `Backend/supabase/functions/_shared/rate_limiter.ts:184` already
--     passes all 5 named args (including `p_increment`).
--   - `Backend/supabase/tests/rate_limit_test.ts` and
--     `ops_admin_router_test.ts` pass only 4 named args — those calls
--     resolve to the 5-arg form with `p_increment` defaulting to TRUE
--     (which is the historical 4-arg behavior).
--   - No SQL caller (PERFORM/SELECT) of the function exists in
--     migrations or RPCs.
--
-- Idempotency: DROP IF EXISTS + REVOKE/GRANT are upsert-style; safe
-- to re-apply.

DROP FUNCTION IF EXISTS stir_rate_limit_check(TEXT, TEXT, INTEGER, INTEGER);

REVOKE EXECUTE ON FUNCTION stir_rate_limit_check(TEXT, TEXT, INTEGER, INTEGER, BOOLEAN)
  FROM PUBLIC, anon, authenticated;

GRANT  EXECUTE ON FUNCTION stir_rate_limit_check(TEXT, TEXT, INTEGER, INTEGER, BOOLEAN)
  TO service_role;

COMMENT ON FUNCTION stir_rate_limit_check(TEXT, TEXT, INTEGER, INTEGER, BOOLEAN) IS
  'Atomic sliding-window rate-limit check (and optionally increment). p_increment defaults TRUE for backward compat with the original 4-arg signature; pass FALSE for the first gate of a layered/composite policy so only the winning gate writes a bucket row. Advisory-locked on (scope,bucket) for concurrency safety. Service-role only (SA2-01 lockdown re-asserted on this overload by SCA-285). SCA-248 + SCA-285.';
