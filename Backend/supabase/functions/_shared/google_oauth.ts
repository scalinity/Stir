// Google OAuth service-account → access-token helper.
//
// Purpose: mint a short-lived Bearer access token for the Gemini Live
// `POST /v1alpha/auth_tokens` endpoint, which per ADR 0006 rejects API-key
// auth. Triggered from `ai-realtime-session`; shared so any future endpoint
// that needs Google OAuth can reuse it.
//
// Flow (standard service-account JWT flow):
//   1. Parse `GCP_SERVICE_ACCOUNT_JSON` secret → { private_key, client_email }.
//   2. Build JWT with RS256 signature, standard aud/scope/iss/exp claims.
//   3. POST `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer` +
//      `assertion=<jwt>` to https://oauth2.googleapis.com/token.
//   4. Response: { access_token, expires_in, token_type: "Bearer" }.
//   5. Cache in memory for (expires_in − 60s). Concurrent requests during
//      a cache miss dedupe via the pending-promise pattern.
//
// Scope: `https://www.googleapis.com/auth/cloud-platform` (broadest; Google's
// own SDKs default to this). Narrower `.../generative-language` is an option
// if we later lock down the SA; for v1, broader scope reduces "wrong scope"
// class of 403s without expanding what the SA can actually do (it's limited
// by its IAM role, not its token scope).

import { decodeBase64 } from 'https://deno.land/std@0.224.0/encoding/base64.ts';
import { encodeBase64Url } from 'https://deno.land/std@0.224.0/encoding/base64url.ts';

const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const SCOPE = 'https://www.googleapis.com/auth/cloud-platform';

const REFRESH_SKEW_SEC = 60;  // refresh this many seconds before actual expiry

interface ServiceAccountJSON {
  type: string;
  project_id: string;
  private_key_id: string;
  private_key: string;      // PEM-formatted RSA private key
  client_email: string;
  client_id: string;
  auth_uri: string;
  token_uri: string;
}

interface CachedToken {
  accessToken: string;
  expiresAtMs: number;
}

// Module-level cache + in-flight dedupe. Edge Function instances are
// single-threaded per request, but the same instance can serve many
// concurrent requests; without dedupe, a cache miss would trigger N
// parallel OAuth exchanges on N concurrent mint calls.
let cached: CachedToken | null = null;
let inFlight: Promise<string> | null = null;
let cachedCryptoKey: CryptoKey | null = null;

export class GoogleOAuthError extends Error {
  public readonly reason?: unknown;
  constructor(message: string, reason?: unknown) {
    super(message);
    this.name = 'GoogleOAuthError';
    this.reason = reason;
  }
}

/**
 * Returns a valid (unexpired) OAuth access token for the Stir service
 * account. Caches in memory until `expires_in - 60s`; concurrent callers
 * during a cache miss share a single OAuth exchange.
 *
 * Throws GoogleOAuthError if the service-account JSON is missing, malformed,
 * or the token exchange fails.
 */
export async function getGoogleAccessToken(): Promise<string> {
  const now = Date.now();
  if (cached && cached.expiresAtMs > now) {
    return cached.accessToken;
  }

  // Dedupe concurrent refreshes. First caller wins; followers await the
  // same promise and reuse the resulting token.
  if (inFlight) {
    return inFlight;
  }

  inFlight = refreshAccessToken().finally(() => {
    inFlight = null;
  });
  return inFlight;
}

async function refreshAccessToken(): Promise<string> {
  const saRaw = Deno.env.get('GCP_SERVICE_ACCOUNT_JSON');
  if (!saRaw) {
    throw new GoogleOAuthError(
      'GCP_SERVICE_ACCOUNT_JSON is not set. See docs/runbooks/gemini-service-account-provisioning.md.',
    );
  }
  let sa: ServiceAccountJSON;
  try {
    sa = JSON.parse(saRaw) as ServiceAccountJSON;
  } catch (err) {
    throw new GoogleOAuthError('GCP_SERVICE_ACCOUNT_JSON is not valid JSON', err);
  }
  if (!sa.private_key || !sa.client_email) {
    throw new GoogleOAuthError('GCP_SERVICE_ACCOUNT_JSON missing private_key or client_email');
  }

  const signedJwt = await signServiceAccountJwt(sa);

  const form = new URLSearchParams();
  form.set('grant_type', 'urn:ietf:params:oauth:grant-type:jwt-bearer');
  form.set('assertion', signedJwt);

  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: form.toString(),
  });
  if (!res.ok) {
    const bodyText = await res.text();
    throw new GoogleOAuthError(`token exchange failed: ${res.status} ${bodyText.slice(0, 300)}`);
  }
  const body = await res.json() as { access_token?: string; expires_in?: number; token_type?: string };
  if (!body.access_token || typeof body.expires_in !== 'number') {
    throw new GoogleOAuthError(`token exchange returned malformed body: ${JSON.stringify(body).slice(0, 200)}`);
  }

  const expiresAtMs = Date.now() + (body.expires_in - REFRESH_SKEW_SEC) * 1000;
  cached = { accessToken: body.access_token, expiresAtMs };
  return body.access_token;
}

async function signServiceAccountJwt(sa: ServiceAccountJSON): Promise<string> {
  const header = {
    alg: 'RS256',
    typ: 'JWT',
    kid: sa.private_key_id,
  };
  const nowSec = Math.floor(Date.now() / 1000);
  const claims = {
    iss: sa.client_email,
    scope: SCOPE,
    aud: TOKEN_URL,
    iat: nowSec,
    exp: nowSec + 3600,  // 1 hour — maximum Google allows
  };
  const enc = new TextEncoder();
  const headerB64 = encodeBase64Url(enc.encode(JSON.stringify(header)));
  const claimsB64 = encodeBase64Url(enc.encode(JSON.stringify(claims)));
  const signingInput = `${headerB64}.${claimsB64}`;

  const key = await getCryptoKey(sa.private_key);
  const signature = await crypto.subtle.sign(
    { name: 'RSASSA-PKCS1-v1_5' },
    key,
    enc.encode(signingInput),
  );
  const signatureB64 = encodeBase64Url(new Uint8Array(signature));
  return `${signingInput}.${signatureB64}`;
}

async function getCryptoKey(pemPrivateKey: string): Promise<CryptoKey> {
  if (cachedCryptoKey) return cachedCryptoKey;
  const pem = pemPrivateKey.replace(/\r\n/g, '\n').trim();
  const body = pem
    .replace(/^-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----$/, '')
    .replace(/\s+/g, '');
  const der = decodeBase64(body);
  // Copy into a fresh, non-shared ArrayBuffer so the pkcs8 import overload
  // accepts it. `der.buffer` has type `ArrayBufferLike` (could be
  // SharedArrayBuffer at the type level) which WebCrypto imports reject.
  const derBuf = new ArrayBuffer(der.byteLength);
  new Uint8Array(derBuf).set(der);
  const key = await crypto.subtle.importKey(
    'pkcs8',
    derBuf,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  cachedCryptoKey = key;
  return key;
}

/**
 * FOR TESTS ONLY — reset the in-memory caches so tests exercise the full
 * refresh path. Not exported via public surface documentation; consumers
 * use `getGoogleAccessToken()` and never this.
 */
export function _resetGoogleOAuthCacheForTests(): void {
  cached = null;
  inFlight = null;
  cachedCryptoKey = null;
}
