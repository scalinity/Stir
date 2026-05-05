// Admin-auth verification for /v1/ops/admin/* Edge Functions.
//
// Parallel path to _shared/auth.ts (which handles iOS session JWTs). Step 8
// ADR 0023 "Admin auth via Supabase Auth + ops_admins" covers the design:
//
//   1. Admins log into the ops SPA via Supabase Auth magic link.
//   2. Supabase Auth mints a JWT signed by whichever key is currently
//      active. Two key systems coexist on Supabase right now:
//        - Legacy: a single HS256 secret (formerly STIR_JWT_SECRET).
//        - New "JWT Signing Keys": a JWKS-style key set with `kid` headers,
//          supporting HS256 and ECDSA P-256 keys; rotatable; standby slot.
//      We verify against the project's JWKS endpoint, which exposes BOTH
//      systems' current keys, so the same code path handles either era of
//      JWT without a manual STIR_JWT_SECRET sync (the previous design's
//      pain point — secret drift between Supabase project and the
//      ops-admin function silently broke admin sign-in with
//      `signature_invalid`).
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

// ---------------------------------------------------------------------------
// Key resolution
// ---------------------------------------------------------------------------

// SUPABASE_URL is auto-injected in Edge Function runtimes (per CLAUDE.md
// "Auto-injected in deployed Edge Functions"). Locally it's
// http://127.0.0.1:54321 / .com / .co; in prod, https://<ref>.supabase.co.
const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
if (!SUPABASE_URL) {
  throw new Error(
    'admin_auth: SUPABASE_URL missing from environment. Required to resolve the project JWKS endpoint.',
  );
}

const JWKS_URL = new URL(`${SUPABASE_URL.replace(/\/$/, '')}/auth/v1/.well-known/jwks.json`);

// jose's remote JWKS resolver: caches the JWKS in memory, refreshes on
// cache-miss kid (the typical case after a key rotation). The cooldown
// prevents thundering-herd refresh storms on a malformed-kid attack.
const JWKS = jose.createRemoteJWKSet(JWKS_URL, {
  cooldownDuration: 30_000,        // ≥30s between refresh attempts on miss
  cacheMaxAge: 10 * 60_000,        // discard cached JWKS after 10min
});

// Legacy fallback secret — kept for backwards-compat with JWTs that were
// minted BEFORE Supabase added `kid` headers. jose's JWKS resolver
// requires `kid` to pick a key; tokens without `kid` fail with
// JWKSNoMatchingKey. If STIR_JWT_SECRET is still set, we retry against
// it. This is the bridge that keeps existing operator JWTs working
// during the migration window. Future: remove this branch once all
// active operator sessions have been re-issued under JWKS.
const LEGACY_SECRET = Deno.env.get('STIR_JWT_SECRET');
const LEGACY_SECRET_BYTES = LEGACY_SECRET
  ? new TextEncoder().encode(LEGACY_SECRET)
  : null;

// Local Auth issuer (Supabase CLI gotrue) vs production.
// Token.iss looks like "http://127.0.0.1:54321/auth/v1" locally and
// "https://<project>.supabase.co/auth/v1" in prod. We match on the
// trailing "/auth/v1" path segment to accept both.
const SUPABASE_AUTH_ISSUER_SUFFIX = '/auth/v1';

// Stir iOS session JWT issuer — MUST reject tokens carrying this iss
// when they're presented to /v1/ops/admin/*. Belt-and-suspenders with
// the auth/v1 suffix check above.
const STIR_SESSION_ISSUER = 'stir-backend';

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// verifyAdminAuth
// ---------------------------------------------------------------------------

/**
 * Verify the Authorization header on an incoming /v1/ops/admin request.
 *
 * Throws AdminAuthError with a typed `reason` on any failure path. The
 * ops-admin router maps the reason to an HTTP response:
 *   - missing / malformed / expired / signature_invalid → 401 AUTH-01 (with reason)
 *   - wrong_issuer / wrong_audience                     → 401 AUTH-01 signature_invalid-equivalent
 *   - not_admin                                         → 403 BILL-01 (or custom)
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

  const payload = await verifyAgainstJwksWithLegacyFallback(token);

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

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

/**
 * Two key paths coexist on Supabase right now:
 *   - HS256 (symmetric, legacy + new "Shared Secret" keys): jose's
 *     createRemoteJWKSet REFUSES to serve symmetric keys via JWKS for
 *     security reasons (a public JWKS endpoint serving the secret
 *     would defeat the whole point), so we MUST verify HS256 against
 *     the local STIR_JWT_SECRET.
 *   - ES256 / RS256 / EdDSA (asymmetric, new JWT Signing Keys): public
 *     keys are served via the JWKS endpoint; jose looks up the right
 *     one by `kid`.
 *
 * Strategy: peek at the JWT's `alg` header, then dispatch. Maps every
 * jose error class to an AdminAuthError reason for stable AUTH-01
 * envelope semantics on the wire.
 */
async function verifyAgainstJwksWithLegacyFallback(token: string): Promise<jose.JWTPayload> {
  let alg: string | undefined;
  try {
    const header = jose.decodeProtectedHeader(token);
    alg = typeof header.alg === 'string' ? header.alg : undefined;
  } catch (err) {
    throw mapJoseError(err);
  }

  // Decode kid + iss for diagnostics (best-effort; never throws here).
  let kid: string | undefined;
  let issForLog: string | undefined;
  try {
    const header = jose.decodeProtectedHeader(token);
    kid = typeof header.kid === 'string' ? header.kid : undefined;
    const parts = token.split('.');
    if (parts.length >= 2) {
      const payloadJson = JSON.parse(
        new TextDecoder().decode(jose.base64url.decode(parts[1]!)),
      );
      issForLog = typeof payloadJson?.iss === 'string' ? payloadJson.iss : undefined;
    }
  } catch (_) {
    // ignore — diagnostics only
  }

  // SA3-Medium / SA2-Medium fix: diagnostics (alg/kid/iss/legacy_secret_len) go
  // ONLY to the server-side `console.error` line below — never into the thrown
  // AdminAuthError.message. ops-admin/index.ts echoes message back to clients
  // on AUTH-01, which would leak STIR_JWT_SECRET byte length + JWKS kid/iss
  // fingerprint to unauthenticated probers (CWE-209/CWE-200).

  // HS256 path: must use static secret.
  if (alg === 'HS256') {
    if (!LEGACY_SECRET_BYTES) {
      console.error(
        `admin_auth_diag alg=HS256 kid=${kid ?? '(none)'} iss=${issForLog ?? '(none)'} reason=no_legacy_secret legacy_secret_len=${LEGACY_SECRET ? LEGACY_SECRET.length : 0}`,
      );
      throw new AdminAuthError(
        'signature_invalid',
        'JWT alg=HS256 requires STIR_JWT_SECRET, which is not configured',
      );
    }
    try {
      const verified = await jose.jwtVerify(token, LEGACY_SECRET_BYTES, {
        algorithms: ['HS256'],
        audience: 'authenticated',
      });
      return verified.payload;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(
        `admin_auth_diag alg=HS256 kid=${kid ?? '(none)'} iss=${issForLog ?? '(none)'} jose_err=${msg} legacy_secret_len=${LEGACY_SECRET ? LEGACY_SECRET.length : 0}`,
      );
      const wrapped = mapJoseError(err);
      throw new AdminAuthError(wrapped.reason, wrapped.message);
    }
  }

  // Asymmetric path: JWKS lookup by `kid`.
  try {
    const verified = await jose.jwtVerify(token, JWKS, {
      algorithms: ['ES256', 'RS256', 'EdDSA'],
      audience: 'authenticated',
    });
    return verified.payload;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(
      `admin_auth_diag alg=${alg ?? '(none)'} kid=${kid ?? '(none)'} iss=${issForLog ?? '(none)'} jose_err=${msg} legacy_secret_len=${LEGACY_SECRET ? LEGACY_SECRET.length : 0}`,
    );
    const wrapped = mapJoseError(err);
    throw new AdminAuthError(wrapped.reason, wrapped.message);
  }
}

function mapJoseError(err: unknown): AdminAuthError {
  const msg = err instanceof Error ? err.message : String(err);
  if (err instanceof jose.errors.JWTExpired) return new AdminAuthError('expired', msg);
  if (err instanceof jose.errors.JWSSignatureVerificationFailed) {
    return new AdminAuthError('signature_invalid', msg);
  }
  if (err instanceof jose.errors.JWSInvalid) return new AdminAuthError('malformed', msg);
  if (err instanceof jose.errors.JWTInvalid) return new AdminAuthError('malformed', msg);
  if (err instanceof jose.errors.JWTClaimValidationFailed) {
    // jose bundles aud + exp + iss into this error class. Re-map based
    // on which claim failed. claim is available on the error.
    // deno-lint-ignore no-explicit-any
    const failedClaim = (err as any).claim as string | undefined;
    if (failedClaim === 'aud') return new AdminAuthError('wrong_audience', msg);
    return new AdminAuthError('signature_invalid', msg);
  }
  if (err instanceof jose.errors.JWKSNoMatchingKey ||
      err instanceof jose.errors.JWKSMultipleMatchingKeys) {
    // Fell here only when LEGACY_SECRET wasn't configured for fallback.
    return new AdminAuthError(
      'signature_invalid',
      `JWKS lookup failed (${msg}); STIR_JWT_SECRET fallback is not configured`,
    );
  }
  return new AdminAuthError('malformed', msg);
}

// ---------------------------------------------------------------------------
// HTTP mapping
// ---------------------------------------------------------------------------

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
