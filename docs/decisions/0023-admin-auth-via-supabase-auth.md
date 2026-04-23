# ADR 0023: Admin auth via Supabase Auth + `ops_admins` link table (separate JWT path from iOS session JWT)

- **Status**: Proposed
- **Date**: 2026-04-23
- **Owner-step**: Step 8 (ops layer)
- **Related**: Spec §14 Admin & Ops Tooling; Spec §13 Security (web2); CLAUDE.md §AUTH-01 response shape + error matrix; `Backend/supabase/migrations/20260423000004_init_ops_admins.sql`; `Backend/supabase/functions/_shared/admin_auth.ts`; `Backend/supabase/functions/_shared/auth.ts` (iOS session JWT, parallel path)

## Context

Step 8 ships an ops console SPA + `/v1/ops/admin/*` Edge Function routes. The existing auth machinery handles iOS session JWTs (minted by `/v1/session/bootstrap`, HS256-signed, `sub = canonical_user_key`, `iss = 'stir-backend'`). Ops admins need a different auth path: email-based, small population, human-reviewed, with no iOS client in the mix. Reusing the iOS session-JWT machinery would force admins into a Sign-in-with-Apple flow plus a separate canonical_user_key — neither fits the "human logs in to a web console" shape.

Two JWT shapes now coexist under the same HS256 secret (`STIR_JWT_SECRET`):

| | iOS session JWT (`_shared/auth.ts`) | Admin Supabase Auth JWT (`_shared/admin_auth.ts`) |
| --- | --- | --- |
| `iss` | `stir-backend` | `http://127.0.0.1:54321/auth/v1` (local) / `https://<project>.supabase.co/auth/v1` (prod) |
| `sub` | `canonical_user_key` string (`ck:_...` or `install:<uuid>`) | `auth.users.id` (UUID) |
| `aud` | `authenticated` | `authenticated` |
| role | `authenticated` | `authenticated` |
| HS256 secret | shared | shared |

The confusable surfaces are (a) the shared secret, (b) the shared `aud`, and (c) both paths accepting `role=authenticated`. If a verifier trusts only `aud` + signature, either token passes either path.

## Decision

**Double-gate admin auth** with a dedicated `ops_admins` link table + a Supabase Auth magic-link flow:

1. `public.ops_admins (auth_user_id UUID PK → auth.users.id, email, created_at, notes)` — provisioned manually (SQL editor). Row present ⇒ admin.
2. `public.is_admin()` — SECURITY DEFINER `plpgsql` function that reads `auth.uid()` and checks `ops_admins`. Fail-closes on ANY exception (`EXCEPTION WHEN OTHERS THEN RAISE WARNING ... RETURN false`). Used by RLS USING clauses on `ops_flagged_outputs`, `audit_log`, `cost_anomalies`.
3. `_shared/admin_auth.ts::verifyAdminAuth` — Edge Function boundary. Rejects tokens that:
   - carry `iss === 'stir-backend'` (iOS session JWT sneaked in)
   - carry `iss` not ending with `/auth/v1`
   - carry `sub` that isn't a UUID (defense in depth; iOS `sub` is a string)
   - fail audience / signature / expiry verification
   - verify cleanly but have no `ops_admins` row
4. `/v1/ops/admin/*` routes call `verifyAdminAuth` first; on success call SECURITY DEFINER RPCs via service-role client. RPCs internally gate on `is_admin() OR auth.jwt()->>'role' = 'service_role'` so they work both under the Edge Function path (service_role) and a hypothetical future admin-direct-PostgREST path (admin JWT). Grants: `EXECUTE TO service_role` only; REVOKE'd from `authenticated` + `anon` + `PUBLIC`.

**Parallel negative tests** (`admin_auth_test.ts`): both JWT types are explicitly rejected on the wrong endpoint.

## Alternatives considered

- **Reuse iOS session JWT machinery** — forces admins through Sign-in-with-Apple + a synthetic canonical_user_key. Rejected: bad UX for a 1–5-person admin population, mixes two orthogonal identity systems, harder to reason about.
- **OAuth (Google Workspace) + custom claim** — industry-standard, nice UX. Rejected for v1: requires new identity provider plumbing, magic-link is adequate for a handful of admins, and Supabase Auth is already a project dependency.
- **Skip the `ops_admins` table; gate on `auth.users.email` domain match (e.g., `*@stir.app`)** — zero schema cost. Rejected: email-domain gates grant authority implicitly with DNS changes; a compromised domain subdomain is sufficient to become admin. Explicit link table + manual provisioning is safer at this scale.
- **Separate Supabase project for ops** — full isolation. Rejected: doubles the deploy surface, complicates cross-project RLS on user data.

## Consequences

### Positive

- Admin + iOS JWT paths can't be confused — `iss` + `sub`-shape guards reject cross-path tokens at the Edge Function boundary.
- `is_admin()` is safe to call from RLS USING clauses on ops tables without risk of 500s on malformed JWTs.
- RPC `EXECUTE TO service_role` + Edge Function boundary gate gives two independent layers — compromising one doesn't unlock ops surfaces.
- Magic-link flow keeps admin provisioning a short SQL insert + a click, matching Daniel-as-solo-admin scale.

### Negative

- Two auth paths = two sets of error codes to think through; iOS `AUTH-01 reason` values are unrelated to `AdminAuthReason` values. Divergent error vocabularies are a minor but real drag.
- Manual provisioning doesn't scale; if admin count grows past ~10 people we'd want a self-service signup + invite flow. Step 9+ problem.
- `STIR_JWT_SECRET` is shared between both paths. A secret leak compromises both. Mitigation: the `ops_admins` lookup requires a real `auth.users` row AND a DB insert; forgery of a JWT alone doesn't grant access.

### Tradeoffs

- We pay schema complexity (new table + RLS + `is_admin()` function + 2 shared helpers) for the right to keep iOS auth + admin auth fully separate. Worth it — the alternative (shared machinery) would have leaked across the boundary in ways that only surface in security review.

## Notes

- **`is_admin()` `EXCEPTION WHEN OTHERS`** — the original `LANGUAGE sql` version let `auth.uid()`'s UUID-cast failures bubble up and 500'd RLS checks whenever a non-UUID `sub` hit (iOS session JWT path into an ops table). Moved to `plpgsql` with `EXCEPTION WHEN OTHERS THEN RAISE WARNING ... RETURN false`. Fail-closed is the only correct auth-check posture. `RAISE WARNING` surfaces unexpected branches in Postgres logs without masking bugs — expected cases (iOS JWT, service-role demo JWT with `sub=""`) emit noise, which is the acceptable cost of not silently eating real regressions.
- **RPC `is_admin() OR auth.role()='service_role'`** — the `auth.role()` branch is load-bearing for the Edge Function path (service-role client has no `auth.uid()`). The pure `is_admin()` branch is load-bearing for the defense-in-depth path where an admin's JWT would hit PostgREST directly (not currently used; reserved for a future SQL-console power-user path).
- **Admin JWT shape** — test helper (`tests/_helpers/admin_factory.ts`) mints JWTs matching the Supabase Auth gotrue shape (`aal: 'aal1'`, `session_id`, `user_metadata`, etc.). Production tokens come from `supabase.auth.admin.createUser` + magic-link sign-in; same claim shape. Tests use `mintAdminAuthJWT` as an indistinguishable substitute.
- **CHECK on admin-only tables uses `is_admin()`** — `ops_flagged_outputs`, `audit_log`, `cost_anomalies` all have RLS policies `USING (public.is_admin())`. RPC-layer grants are the primary gate; RLS is belt-and-suspenders against accidental `GRANT EXECUTE TO authenticated` regressions on future RPCs.
- **Provisioning**: `INSERT INTO ops_admins (auth_user_id, email, notes) VALUES ('<uuid>', 'admin@example.com', 'founder seed 2026-04-23');` via Supabase dashboard SQL editor. Day-one admin seed is Daniel (scalinity.ai@gmail.com). Runbook: `docs/runbooks/ops-admin-provisioning.md` (Phase 9).
- **Supersedes nothing**; parallel path to `_shared/auth.ts` (step 1). `_shared/auth.ts` is unchanged.
