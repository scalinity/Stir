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
import { createServiceClient } from './db.ts';
import type { AuthReason } from './errors.ts';
import { createLogger } from './logger.ts';

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

// Cached module-scope service client for the reauth check. One per
// Edge Function worker — amortizes the createClient() cost (tens of µs)
// across many verifies within the worker's ~30-min lifetime.
let reauthCheckClient: SupabaseClient | null = null;
function reauthClient(): SupabaseClient {
  if (!reauthCheckClient) reauthCheckClient = createServiceClient();
  return reauthCheckClient;
}

/**
 * Verify the session JWT on an incoming Request. Throws AuthError with a
 * typed `reason` for missing / malformed / expired / signature_invalid /
 * reauth_required.
 *
 * The handler catches AuthError and returns 401 with AUTH-01 + reason.
 *
 * Force-reauth gate (ADR 0023, review C1 fix): after JWT verification the
 * reauth check ALWAYS runs — previously the gate was behind an optional
 * `client` parameter no caller ever passed, making users.force_reauth a
 * no-op feature. We now create a module-scope service client internally,
 * following the app_users.merged_into chain one hop so an alias-forwarded
 * user is still kicked when their merged target has reauth_required_at
 * set (review W39). The DB error path fails open with a log.warn —
 * transient Postgres blips shouldn't invalidate every in-flight session,
 * but a permanent fault surfaces via the log event.
 *
 * The optional `client` argument is preserved for tests that want to
 * inject a mock client; production handlers should omit it.
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
      // Issuer/audience/etc. mismatch on a JWT whose signature verifies
      // cleanly. This is config drift (mint and verify disagree on issuer
      // or audience strings), NOT signature forgery. Map to 'malformed'
      // so iOS treats it as info-severity silent re-bootstrap rather than
      // tripping the signature_invalid alert path. SA2-H2 step-9 review.
      throw new AuthError('malformed', msg);
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

  // Force-reauth gate (ADR 0023, review C1 fix). Always runs after JWT
  // verification. Single indexed PK lookup + at most one merged_into hop
  // (~1-3 ms total). Uses caller-supplied client when present (test seam),
  // else the module-scope reauth client.
  //
  // Semantics: admin sets `reauth_required_at = now()` via users.force_reauth;
  // any existing JWT (iat <= now()) is rejected with reason=reauth_required
  // on its next verifying call. iOS maps that reason to SIWA re-flow; fresh
  // JWT minted after the bump passes naturally (iat > reauth_required_at).
  //
  // merged_into follow: an alias-forwarded user whose install-keyed row
  // holds `status='merged' AND merged_into=<ck>` is kicked when the ck
  // target has reauth_required_at set. Without this, admin force_reauth
  // on the target never reaches the install-keyed JWT holder (review W39).
  const checkClient = client ?? reauthClient();
  const reauthLog = await createLogger('_shared/auth', '_shared/auth.verifySessionJWT');
  try {
    const { data: row, error: rowErr } = await checkClient
      .from('app_users')
      .select('reauth_required_at, merged_into')
      .eq('canonical_user_key', canonical_user_key)
      .maybeSingle<{ reauth_required_at: string | null; merged_into: string | null }>();

    if (rowErr) {
      // Fail-open with observability — a permanent fault should surface.
      reauthLog.warn('reauth_check_db_error', {
        err: rowErr.message,
        canonical_user_key_hash: await hashKeyForLog(canonical_user_key),
      });
    } else if (row) {
      // Direct hit on the claim's key.
      await rejectIfReauthRequired(iat, row.reauth_required_at);

      // If the row is a merged alias, also check the winning target.
      if (row.merged_into) {
        const { data: target, error: targetErr } = await checkClient
          .from('app_users')
          .select('reauth_required_at')
          .eq('canonical_user_key', row.merged_into)
          .maybeSingle<{ reauth_required_at: string | null }>();

        if (targetErr) {
          reauthLog.warn('reauth_check_merged_target_db_error', {
            err: targetErr.message,
          });
        } else if (target) {
          await rejectIfReauthRequired(iat, target.reauth_required_at);
        }
      }
    }
  } catch (err) {
    // Rethrow AuthError; swallow anything else fail-open (observability above).
    if (err instanceof AuthError) throw err;
    reauthLog.warn('reauth_check_unexpected', {
      err: err instanceof Error ? err.message : String(err),
    });
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

async function rejectIfReauthRequired(iat: number, reauthRequiredAt: string | null): Promise<void> {
  if (!reauthRequiredAt) return;
  const reauthAtMs = Date.parse(reauthRequiredAt);
  if (Number.isNaN(reauthAtMs)) return;
  const reauthAtSec = Math.floor(reauthAtMs / 1000);
  // iat <= reauthAt (not strict <): JWTs issued in the same second as the
  // force-reauth bump are rejected. JWT iat is second-precision; Postgres
  // now() is microsecond-precision but truncates to seconds on the JWT
  // side, so same-second collisions are realistic (review W5).
  if (iat <= reauthAtSec) {
    throw new AuthError(
      'reauth_required',
      `JWT iat=${iat} predates reauth_required_at=${reauthAtSec}`,
    );
  }
}

async function hashKeyForLog(key: string): Promise<string> {
  // Lightweight PII-safe key fingerprint for log correlation. Not a full
  // hashCanonicalKey (which lives in _shared/hashing.ts and is async-heavy
  // for tight-loop calls) — just enough for "same user keeps failing"
  // pattern detection in logs.
  const buf = new TextEncoder().encode(key);
  const hash = await crypto.subtle.digest('SHA-256', buf);
  return Array.from(new Uint8Array(hash).slice(0, 4))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}
