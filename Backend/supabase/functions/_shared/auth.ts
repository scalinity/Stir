// Session JWT mint + verify. HS256, 24h TTL, signed with SUPABASE_JWT_SECRET.
//
// Mint claims match Supabase PostgREST expectations so RLS works natively:
//   iss: 'stir-backend'
//   aud: 'authenticated'   (PostgREST rejects mismatched aud by default)
//   role: 'authenticated'  (PostgREST sets SET ROLE from this claim)
//   sub: canonical_user_key
//   canonical_user_key: <same>  (redundant-but-explicit; RLS reads this)
//   installation_id: <uuid>
//   tier: free | premium | pro
//   iat, exp
//
// Verify throws AuthError with typed `reason`, which the handler maps
// to AUTH-01 responses with the reason field preserved for iOS.

import * as jose from 'jose';
import type { SupabaseClient } from '@supabase/supabase-js';
import type { AuthReason } from './errors.ts';

// Named STIR_JWT_SECRET (not SUPABASE_JWT_SECRET) because Supabase's Edge
// Runtime filters SUPABASE_*-prefixed vars from .env to protect reserved
// names. For RLS to work, this value MUST match the project's PostgREST
// jwt_secret (visible via `supabase status -o json` locally).
const JWT_SECRET = Deno.env.get('STIR_JWT_SECRET');
if (!JWT_SECRET) {
  throw new Error(
    'STIR_JWT_SECRET missing from environment. Required for session JWT mint/verify. Must equal Supabase project jwt_secret so PostgREST validates our JWTs for RLS.',
  );
}

const SECRET_BYTES = new TextEncoder().encode(JWT_SECRET);

export const DEFAULT_JWT_TTL_SECONDS = 24 * 60 * 60; // 24h per spec §10

export type UserTier = 'free' | 'premium' | 'pro';

export interface SessionClaims {
  canonical_user_key: string;
  installation_id: string;
  tier: UserTier;
}

export interface VerifiedSessionClaims extends SessionClaims {
  iat: number;
  exp: number;
  sub: string;
}

export class AuthError extends Error {
  readonly reason: AuthReason;
  constructor(reason: AuthReason, message?: string) {
    super(message ?? `auth failed: ${reason}`);
    this.name = 'AuthError';
    this.reason = reason;
  }
}

/** Issue a session JWT signed with HS256. */
export async function issueSessionJWT(
  claims: SessionClaims,
  opts: { ttlSeconds?: number } = {},
): Promise<string> {
  const ttl = opts.ttlSeconds ?? DEFAULT_JWT_TTL_SECONDS;
  const now = Math.floor(Date.now() / 1000);
  return await new jose.SignJWT({
    canonical_user_key: claims.canonical_user_key,
    installation_id: claims.installation_id,
    tier: claims.tier,
    role: 'authenticated',
  })
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setIssuer('stir-backend')
    .setAudience('authenticated')
    .setSubject(claims.canonical_user_key)
    .setIssuedAt(now)
    .setExpirationTime(now + ttl)
    .sign(SECRET_BYTES);
}

/**
 * Verify the session JWT on an incoming Request. Throws AuthError with a
 * typed `reason` for missing / malformed / expired / signature_invalid.
 *
 * The handler catches AuthError and returns 401 with AUTH-01 + reason.
 *
 * Optional `client` parameter (Phase 2, step-8 ADR 0023): when provided,
 * queries `app_users.reauth_required_at` after JWT verification succeeds.
 * If `reauth_required_at > JWT.iat` the JWT is rejected with reason
 * `reauth_required`. Set by the admin `users.force_reauth` action; iOS
 * maps this reason to a Sign-in-with-Apple re-flow rather than the
 * silent-retry path used for expired/missing. Callers that don't care
 * about force-reauth (e.g., endpoints that don't touch app_users at all)
 * can omit the client — existing call sites stay backward-compatible.
 */
export async function verifySessionJWT(
  req: Request,
  client?: SupabaseClient,
): Promise<VerifiedSessionClaims> {
  const header = req.headers.get('authorization') ?? req.headers.get('Authorization');
  if (!header) throw new AuthError('missing', 'no Authorization header');

  const match = header.match(/^Bearer\s+(.+)$/);
  if (!match) throw new AuthError('malformed', 'Authorization header is not Bearer <token>');
  const token = match[1]!.trim();
  if (!token) throw new AuthError('malformed', 'Bearer token empty');

  // Cheap structural check before crypto — three base64url segments.
  if (!/^[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+$/.test(token)) {
    throw new AuthError('malformed', 'not a JWS compact-serialization string');
  }

  let payload: jose.JWTPayload;
  try {
    const verified = await jose.jwtVerify(token, SECRET_BYTES, {
      algorithms: ['HS256'],
      issuer: 'stir-backend',
      audience: 'authenticated',
    });
    payload = verified.payload;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    if (err instanceof jose.errors.JWTExpired) throw new AuthError('expired', msg);
    if (err instanceof jose.errors.JWSSignatureVerificationFailed) {
      throw new AuthError('signature_invalid', msg);
    }
    if (err instanceof jose.errors.JWSInvalid) throw new AuthError('malformed', msg);
    if (err instanceof jose.errors.JWTInvalid) throw new AuthError('malformed', msg);
    if (err instanceof jose.errors.JWTClaimValidationFailed) {
      throw new AuthError('signature_invalid', msg);
    }
    // Unknown jose failure. Treat as malformed to avoid leaking internals.
    throw new AuthError('malformed', msg);
  }

  const { canonical_user_key, installation_id, tier, sub, iat, exp } = payload as Record<
    string,
    unknown
  >;

  if (typeof canonical_user_key !== 'string' || !canonical_user_key) {
    throw new AuthError('malformed', 'missing canonical_user_key claim');
  }
  if (typeof installation_id !== 'string' || !installation_id) {
    throw new AuthError('malformed', 'missing installation_id claim');
  }
  if (tier !== 'free' && tier !== 'premium' && tier !== 'pro') {
    throw new AuthError('malformed', 'missing or invalid tier claim');
  }
  if (typeof sub !== 'string' || !sub) {
    throw new AuthError('malformed', 'missing sub claim');
  }
  if (typeof iat !== 'number' || typeof exp !== 'number') {
    throw new AuthError('malformed', 'missing iat/exp');
  }

  // Force-reauth gate (Phase 2, ADR 0023). Only runs when caller supplies a
  // service-role client — lets endpoints that don't touch app_users skip the
  // round-trip. Query is a single indexed PK lookup (~1-2 ms).
  //
  // Semantics: admin sets `reauth_required_at = now()` via users.force_reauth;
  // any existing JWT (iat < now()) is rejected with reason=reauth_required on
  // its next verifying call. iOS maps that reason to SIWA re-flow; fresh JWT
  // minted after the bump passes naturally (iat > reauth_required_at).
  if (client) {
    const { data: row, error: rowErr } = await client
      .from('app_users')
      .select('reauth_required_at')
      .eq('canonical_user_key', canonical_user_key)
      .maybeSingle<{ reauth_required_at: string | null }>();
    // Row-missing is handled by the caller's identity-resolution layer (not
    // our concern here); a DB error doesn't fail closed — we don't want a
    // transient Postgres blip to invalidate every in-flight session.
    if (!rowErr && row && row.reauth_required_at) {
      const reauthAtMs = Date.parse(row.reauth_required_at);
      if (!Number.isNaN(reauthAtMs)) {
        const reauthAtSec = Math.floor(reauthAtMs / 1000);
        if (iat < reauthAtSec) {
          throw new AuthError(
            'reauth_required',
            `JWT iat=${iat} predates reauth_required_at=${reauthAtSec}`,
          );
        }
      }
    }
  }

  return {
    canonical_user_key,
    installation_id,
    tier,
    sub,
    iat,
    exp,
  };
}
