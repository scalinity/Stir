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
import type { AuthReason } from './errors.ts';

const JWT_SECRET = Deno.env.get('SUPABASE_JWT_SECRET');
if (!JWT_SECRET) {
  throw new Error(
    'SUPABASE_JWT_SECRET missing from environment. Required for session JWT mint/verify.',
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
 */
export async function verifySessionJWT(req: Request): Promise<VerifiedSessionClaims> {
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

  return {
    canonical_user_key,
    installation_id,
    tier,
    sub,
    iat,
    exp,
  };
}
