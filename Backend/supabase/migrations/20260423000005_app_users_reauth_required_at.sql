-- Stir operational schema — app_users.reauth_required_at
-- Step 8: force-reauth admin primitive (spec §14 User management).
--
-- Phase-2 enforcement contract (LOCKED, don't drift this):
--   1. `verifySessionJWT` reads `reauth_required_at` per request and
--      compares to the JWT's `iat` claim.
--   2. If `reauth_required_at > iat`, throw AuthError with NEW reason
--      code `reauth_required` (to be added to AuthReason union +
--      CLAUDE.md error matrix + spec §6 when the route lands).
--      Response: 401 AUTH-01 reason=reauth_required.
--   3. iOS `AuthService` maps that reason to a Sign-in-with-Apple
--      re-flow (NOT the generic silent-retry path). Different UX copy:
--      "Please sign in again to continue."
--   4. Admin route `POST /v1/ops/admin/users/:canonical_user_key/force-reauth`
--      sets `reauth_required_at = now()` and writes an audit_log row
--      (`action='users.force_reauth'`).
--
-- Why a timestamp vs boolean: comparing to JWT.iat means a newly issued
-- JWT (iat > reauth_required_at) automatically passes without needing to
-- clear the flag. Force-reauth is self-expiring — set once; old JWTs fail;
-- new JWTs minted after the bump work. Idempotent from the admin's POV.
--
-- Schema-only change in Phase 1. Column defaults NULL (most users never
-- force-reauth). Enforcement + iOS handler + admin route land in Phase 2.

ALTER TABLE app_users
  ADD COLUMN IF NOT EXISTS reauth_required_at TIMESTAMPTZ NULL;

-- Partial index: 99.99%+ of rows sit at NULL (force-reauth is rare). Only
-- index the hot path for admin queries like "which users currently have
-- pending force-reauth?" and for verifySessionJWT's per-request lookup.
CREATE INDEX IF NOT EXISTS idx_app_users_reauth_required_at
  ON app_users(reauth_required_at)
  WHERE reauth_required_at IS NOT NULL;

COMMENT ON COLUMN app_users.reauth_required_at IS
  'Phase-2 contract: verifySessionJWT rejects JWTs with iat < reauth_required_at as AUTH-01 reason=reauth_required. Bumped by admin users.force_reauth action (writes audit_log). iOS maps reason=reauth_required to Sign-in-with-Apple re-flow (not silent retry). Self-expiring — new JWTs with iat > reauth_required_at pass without clearing the flag.';
