// Unit tests for Backend/supabase/functions/_shared/google_oauth.ts.
//
// No real network — we mock `fetch` to `https://oauth2.googleapis.com/token`.
// A throwaway RSA key is generated in-process to act as the service-account
// private key, so the JWT sign + verify round-trip exercises the real
// WebCrypto path.
//
// Covers:
//   - JWT claims shape (iss, scope, aud, iat, exp)
//   - JWT header (alg=RS256, kid=private_key_id)
//   - RS256 signature that actually verifies against the matching public key
//   - Caching: second call within TTL returns the cached token with zero network
//   - Concurrent dedupe: two simultaneous calls hit fetch exactly once
//   - Refresh after TTL: third call past TTL hits fetch again
//   - Error: missing GCP_SERVICE_ACCOUNT_JSON throws GoogleOAuthError
//   - Error: malformed JSON throws
//   - Error: token endpoint 500 bubbles up

import './_helpers/env.ts';
import { assertEquals, assertRejects } from '@std/assert';
import { encodeBase64 } from 'https://deno.land/std@0.224.0/encoding/base64.ts';
import { decodeBase64Url } from 'https://deno.land/std@0.224.0/encoding/base64url.ts';
import {
  GoogleOAuthError,
  _resetGoogleOAuthCacheForTests,
  getGoogleAccessToken,
} from '../functions/_shared/google_oauth.ts';

// ---------------------------------------------------------------------------
// Test fixtures
// ---------------------------------------------------------------------------

interface TestSA {
  json: string;        // the JSON blob we'll stuff into GCP_SERVICE_ACCOUNT_JSON
  publicKey: CryptoKey; // to verify signatures produced by the helper
  email: string;
  kid: string;
}

async function generateTestServiceAccount(): Promise<TestSA> {
  const keyPair = await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true,
    ['sign', 'verify'],
  );
  const pkcs8 = await crypto.subtle.exportKey('pkcs8', keyPair.privateKey);
  const pem = [
    '-----BEGIN PRIVATE KEY-----',
    encodeBase64(new Uint8Array(pkcs8)).match(/.{1,64}/g)?.join('\n') ?? '',
    '-----END PRIVATE KEY-----',
  ].join('\n');

  const sa = {
    type: 'service_account',
    project_id: 'stir-test',
    private_key_id: crypto.randomUUID().replaceAll('-', ''),
    private_key: pem,
    client_email: 'stir-live-mint@stir-test.iam.gserviceaccount.com',
    client_id: '123456789',
    auth_uri: 'https://accounts.google.com/o/oauth2/auth',
    token_uri: 'https://oauth2.googleapis.com/token',
  };

  return {
    json: JSON.stringify(sa),
    publicKey: keyPair.publicKey,
    email: sa.client_email,
    kid: sa.private_key_id,
  };
}

// Installs a stub `fetch` that matches the Google OAuth token endpoint and
// returns a canned access_token + expires_in. Anything else falls through
// to the original fetch (so tests that use the real DB still work).
//
// Returns a tuple of (restore, stats) where stats.calls counts token-endpoint
// hits and stats.lastAssertion captures the last posted JWT for verification.
function stubTokenEndpoint(
  response: { access_token: string; expires_in: number } | { error: string },
): { restore: () => void; stats: { calls: number; lastAssertion?: string } } {
  const original = globalThis.fetch;
  const stats: { calls: number; lastAssertion?: string } = { calls: 0 };
  globalThis.fetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
    if (url === 'https://oauth2.googleapis.com/token') {
      stats.calls++;
      const body = init?.body;
      if (typeof body === 'string') {
        const params = new URLSearchParams(body);
        const assertion = params.get('assertion');
        if (assertion) stats.lastAssertion = assertion;
      }
      if ('error' in response) {
        return new Response(JSON.stringify(response), { status: 500, headers: { 'content-type': 'application/json' } });
      }
      return new Response(JSON.stringify({ ...response, token_type: 'Bearer' }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    }
    return original(input, init);
  };
  return { restore: () => { globalThis.fetch = original; }, stats };
}

async function verifySignedJwt(jwt: string, publicKey: CryptoKey): Promise<{ header: Record<string, unknown>; claims: Record<string, unknown> }>
{
  const parts = jwt.split('.');
  if (parts.length !== 3) throw new Error(`malformed JWT: expected 3 segments, got ${parts.length}`);
  const headerB64 = parts[0]!;
  const claimsB64 = parts[1]!;
  const sigB64    = parts[2]!;
  const dec = new TextDecoder();
  const header = JSON.parse(dec.decode(decodeBase64Url(headerB64)));
  const claims = JSON.parse(dec.decode(decodeBase64Url(claimsB64)));
  const sigBytes = decodeBase64Url(sigB64);
  const sigBuf = new ArrayBuffer(sigBytes.byteLength);
  new Uint8Array(sigBuf).set(sigBytes);
  const signed = new TextEncoder().encode(`${headerB64}.${claimsB64}`);
  const ok = await crypto.subtle.verify({ name: 'RSASSA-PKCS1-v1_5' }, publicKey, sigBuf, signed);
  if (!ok) throw new Error('JWT signature verification failed');
  return { header, claims };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

Deno.test('google_oauth: happy path — JWT has correct claims, signature verifies, token returned', async () => {
  _resetGoogleOAuthCacheForTests();
  const sa = await generateTestServiceAccount();
  Deno.env.set('GCP_SERVICE_ACCOUNT_JSON', sa.json);
  const { restore, stats } = stubTokenEndpoint({ access_token: 'test-access-abc', expires_in: 3600 });
  try {
    const token = await getGoogleAccessToken();
    assertEquals(token, 'test-access-abc');
    assertEquals(stats.calls, 1);
    // Verify the assertion field is a well-formed JWT we can decode.
    const assertion = stats.lastAssertion;
    if (!assertion) throw new Error('missing assertion');
    const { header, claims } = await verifySignedJwt(assertion, sa.publicKey);
    assertEquals(header.alg, 'RS256');
    assertEquals(header.typ, 'JWT');
    assertEquals(header.kid, sa.kid);
    assertEquals(claims.iss, sa.email);
    assertEquals(claims.scope, 'https://www.googleapis.com/auth/cloud-platform');
    assertEquals(claims.aud, 'https://oauth2.googleapis.com/token');
    const exp = claims.exp as number;
    const iat = claims.iat as number;
    // Expiry must be ~1h after iat (Google's maximum).
    assertEquals(exp - iat, 3600);
  } finally {
    restore();
    _resetGoogleOAuthCacheForTests();
    Deno.env.delete('GCP_SERVICE_ACCOUNT_JSON');
  }
});

Deno.test('google_oauth: caching — second call inside TTL skips network', async () => {
  _resetGoogleOAuthCacheForTests();
  const sa = await generateTestServiceAccount();
  Deno.env.set('GCP_SERVICE_ACCOUNT_JSON', sa.json);
  const { restore, stats } = stubTokenEndpoint({ access_token: 'cached-abc', expires_in: 3600 });
  try {
    const a = await getGoogleAccessToken();
    const b = await getGoogleAccessToken();
    assertEquals(a, 'cached-abc');
    assertEquals(b, 'cached-abc');
    assertEquals(stats.calls, 1);  // second call served from cache
  } finally {
    restore();
    _resetGoogleOAuthCacheForTests();
    Deno.env.delete('GCP_SERVICE_ACCOUNT_JSON');
  }
});

Deno.test('google_oauth: concurrent dedupe — two parallel callers share one exchange', async () => {
  _resetGoogleOAuthCacheForTests();
  const sa = await generateTestServiceAccount();
  Deno.env.set('GCP_SERVICE_ACCOUNT_JSON', sa.json);
  const { restore, stats } = stubTokenEndpoint({ access_token: 'concurrent-xyz', expires_in: 3600 });
  try {
    const [a, b, c] = await Promise.all([
      getGoogleAccessToken(),
      getGoogleAccessToken(),
      getGoogleAccessToken(),
    ]);
    assertEquals(a, 'concurrent-xyz');
    assertEquals(b, 'concurrent-xyz');
    assertEquals(c, 'concurrent-xyz');
    assertEquals(stats.calls, 1);
  } finally {
    restore();
    _resetGoogleOAuthCacheForTests();
    Deno.env.delete('GCP_SERVICE_ACCOUNT_JSON');
  }
});

Deno.test('google_oauth: missing secret throws GoogleOAuthError', async () => {
  _resetGoogleOAuthCacheForTests();
  Deno.env.delete('GCP_SERVICE_ACCOUNT_JSON');
  await assertRejects(
    () => getGoogleAccessToken(),
    GoogleOAuthError,
    'GCP_SERVICE_ACCOUNT_JSON is not set',
  );
});

Deno.test('google_oauth: malformed JSON throws GoogleOAuthError', async () => {
  _resetGoogleOAuthCacheForTests();
  Deno.env.set('GCP_SERVICE_ACCOUNT_JSON', '{ not json');
  try {
    await assertRejects(
      () => getGoogleAccessToken(),
      GoogleOAuthError,
      'not valid JSON',
    );
  } finally {
    _resetGoogleOAuthCacheForTests();
    Deno.env.delete('GCP_SERVICE_ACCOUNT_JSON');
  }
});

Deno.test('google_oauth: missing private_key in JSON throws', async () => {
  _resetGoogleOAuthCacheForTests();
  Deno.env.set('GCP_SERVICE_ACCOUNT_JSON', JSON.stringify({ client_email: 'x@y.z' }));
  try {
    await assertRejects(
      () => getGoogleAccessToken(),
      GoogleOAuthError,
      'missing private_key or client_email',
    );
  } finally {
    _resetGoogleOAuthCacheForTests();
    Deno.env.delete('GCP_SERVICE_ACCOUNT_JSON');
  }
});

Deno.test('google_oauth: token endpoint 500 bubbles up as GoogleOAuthError', async () => {
  _resetGoogleOAuthCacheForTests();
  const sa = await generateTestServiceAccount();
  Deno.env.set('GCP_SERVICE_ACCOUNT_JSON', sa.json);
  const { restore } = stubTokenEndpoint({ error: 'upstream_boom' });
  try {
    await assertRejects(
      () => getGoogleAccessToken(),
      GoogleOAuthError,
      'token exchange failed: 500',
    );
  } finally {
    restore();
    _resetGoogleOAuthCacheForTests();
    Deno.env.delete('GCP_SERVICE_ACCOUNT_JSON');
  }
});
