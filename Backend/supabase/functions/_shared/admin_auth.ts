// Admin-auth verification for /v1/ops/admin/* Edge Functions.
//
// Parallel path to _shared/auth.ts (which handles iOS session JWTs). Step 8
// ADR 0023 "Admin auth via Supabase Auth + ops_admins" covers the design:
//
//   1. Admins log into the ops SPA via Supabase Auth magic link.
//   2. Supabase Auth mints an HS256-signed JWT (same STIR_JWT_SECRET the
//      project uses project-wide; PostgREST accepts it natively for RLS).
//   3. The JWT's `sub` is a UUID from `auth.users.id`. iOS session JWTs
//      carry `sub = canonical_user_key` (a string like `ck:...`) so they
//      cannot be confused.
//   4. verifyAdminAuth cross-checks the UUID against `ops_admins` via
//      service-role. Row present = admin. Absent = not admin.
//
// Dual rejection paths — Edge Function AND DB:
//   - Edge Function: this helper throws AdminAuthError if the JWT isn't
//     Supabase-Auth-shaped OR the lookup finds no ops_admins row.
//   - DB: is_admin() RLS USING clause on ops_flagged_outputs, audit_log,
//     cost_anomalies. iOS session JWTs never pass it (sub is non-UUID →
//     SQLSTATE 22P02 → is_admin() returns false).
//
// The two paths are redundant. If an attacker bypasses one (e.g., leaked
// service-role key reading ops tables directly), the other stops them.

import * as jose from 'jose';
import type { SupabaseClient } from '@supabase/supabase-js';

const JWT_SECRET = Deno.env.get('STIR_JWT_SECRET');
if (!JWT_SECRET) {
  throw new Error(
    'admin_auth: STIR_JWT_SECRET missing from environment. Required to verify Supabase Auth JWTs. Must match the project jwt_secret.',
  );
}
const SECRET_BYTES = new TextEncoder().encode(JWT_SECRET);

// Local Auth issuer (Supabase CLI gotrue) vs production.
// Token.iss looks like "http://127.0.0.1:54321/auth/v1" locally and
// "https://<project>.supabase.co/auth/v1" in prod. We match on the
// trailing "/auth/v1" path segment to accept both.
const SUPABASE_AUTH_ISSUER_SUFFIX = '/auth/v1';

// Stir iOS session JWT issuer — MUST reject tokens carrying this iss
// when they're presented to /v1/ops/admin/*. Belt-and-suspenders with
// the auth/v1 suffix check above.
const STIR_SESSION_ISSUER = 'stir-backend';

export type AdminAuthReason =
  | 'missing'
  | 'malformed'
  | 'expired'
  | 'signature_invalid'
  | 'wrong_issuer'
  | 'wrong_audience'
  | 'not_admin';

export class AdminAuthError extends Error {
  readonly reason: AdminAuthReason;
  constructor(reason: AdminAuthReason, message?: string) {
    super(message ?? `admin auth failed: ${reason}`);
    this.name = 'AdminAuthError';
    this.reason = reason;
  }
}

export interface AdminIdentity {
  /** auth.users.id */
  authUserId: string;
  /** Email snapshot from ops_admins (not auth.users, so renames are visible). */
  email: string;
}

/**
 * Verify the Authorization header on an incoming /v1/ops/admin request.
 *
 * Throws AdminAuthError with a typed `reason` on any failure path. The
 * ops-admin router maps the reason to an HTTP response:
 *   - missing / malformed / expired / signature_invalid → 401 AUTH-01 (with reason)
 *   - wrong_issuer / wrong_audience                     → 401 AUTH-01 signature_invalid-equivalent
 *   - not_admin                                         → 403 BILL-01 (or custom)
 *
 * The caller supplies a service-role client (we need to bypass RLS for the
 * ops_admins lookup since RLS only lets admins see their own row — that's
 * circular).
 */
export async function verifyAdminAuth(
  req: Request,
  serviceClient: SupabaseClient,
): Promise<AdminIdentity> {
  const header = req.headers.get('authorization') ?? req.headers.get('Authorization');
  if (!header) {
    throw new AdminAuthError('missing', 'no Authorization header');
  }

  const match = header.match(/^Bearer\s+(.+)$/);
  if (!match) {
    throw new AdminAuthError('malformed', 'Authorization header is not Bearer <token>');
  }
  const token = match[1]!.trim();
  if (!token) {
    throw new AdminAuthError('malformed', 'Bearer token empty');
  }

  // Cheap structural check before crypto — three base64url segments.
  if (!/^[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+$/.test(token)) {
    throw new AdminAuthError('malformed', 'not a JWS compact-serialization string');
  }

  let payload: jose.JWTPayload;
  try {
    const verified = await jose.jwtVerify(token, SECRET_BYTES, {
      algorithms: ['HS256'],
      audience: 'authenticated',
    });
    payload = verified.payload;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    if (err instanceof jose.errors.JWTExpired) throw new AdminAuthError('expired', msg);
    if (err instanceof jose.errors.JWSSignatureVerificationFailed) {
      throw new AdminAuthError('signature_invalid', msg);
    }
    if (err instanceof jose.errors.JWSInvalid) throw new AdminAuthError('malformed', msg);
    if (err instanceof jose.errors.JWTInvalid) throw new AdminAuthError('malformed', msg);
    if (err instanceof jose.errors.JWTClaimValidationFailed) {
      // jose bundles aud + exp + iss into this error class. Re-map based
      // on which claim failed. claim is available on the error.
      // deno-lint-ignore no-explicit-any
      const failedClaim = (err as any).claim as string | undefined;
      if (failedClaim === 'aud') throw new AdminAuthError('wrong_audience', msg);
      // The jwtVerify above only enforces aud; other claim checks we do
      // ourselves below. This branch is for the aud-failure case jose
      // already caught.
      throw new AdminAuthError('signature_invalid', msg);
    }
    throw new AdminAuthError('malformed', msg);
  }

  // Issuer gate: reject iOS session JWTs that slipped through with the
  // same secret + aud. Stir iOS JWT has iss='stir-backend'; Supabase Auth
  // JWTs have iss ending with /auth/v1.
  const iss = typeof payload.iss === 'string' ? payload.iss : '';
  if (iss === STIR_SESSION_ISSUER) {
    throw new AdminAuthError(
      'wrong_issuer',
      'iOS session JWT presented to admin endpoint (iss=stir-backend)',
    );
  }
  if (!iss.endsWith(SUPABASE_AUTH_ISSUER_SUFFIX)) {
    throw new AdminAuthError(
      'wrong_issuer',
      `unexpected iss claim: ${iss || '(empty)'}`,
    );
  }

  // sub MUST be a UUID (auth.users.id). iOS session JWTs carry a
  // canonical_user_key string here; reject.
  const sub = typeof payload.sub === 'string' ? payload.sub : '';
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(sub)) {
    throw new AdminAuthError('wrong_issuer', 'sub is not a UUID (likely iOS session JWT)');
  }

  // ops_admins lookup — single indexed PK query. Service role bypasses RLS.
  const { data, error } = await serviceClient
    .from('ops_admins')
    .select('auth_user_id, email')
    .eq('auth_user_id', sub)
    .maybeSingle<{ auth_user_id: string; email: string }>();

  if (error) {
    throw new AdminAuthError('not_admin', `ops_admins lookup failed: ${error.message}`);
  }
  if (!data) {
    throw new AdminAuthError('not_admin', 'no ops_admins row for auth user');
  }

  return { authUserId: data.auth_user_id, email: data.email };
}

/**
 * Map an AdminAuthError to an HTTP status + code. Centralized so all
 * /v1/ops/admin/* routes render errors consistently.
 */
export function adminAuthErrorHttp(err: AdminAuthError): { status: number; reason: AdminAuthReason } {
  switch (err.reason) {
    case 'not_admin':
      return { status: 403, reason: 'not_admin' };
    case 'missing':
    case 'expired':
    case 'malformed':
    case 'signature_invalid':
    case 'wrong_issuer':
    case 'wrong_audience':
      return { status: 401, reason: err.reason };
  }
}
