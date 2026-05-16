// In-process tests for _shared helpers. No HTTP required — fastest tier
// of the test suite. Covers JWT mint/verify round-trip, canonical-key
// hashing stability, Zod validation edges, and the one-hop-max rule
// on followMergedInto.

import './_helpers/env.ts';
import { assertEquals, assertRejects, assertThrows } from '@std/assert';
import {
  AuthError,
  DEFAULT_JWT_TTL_SECONDS,
  issueSessionJWT,
  verifySessionJWT,
} from '../functions/_shared/auth.ts';
import { hashCanonicalKey } from '../functions/_shared/hashing.ts';
import { SessionBootstrapRequest, zodToFieldErrors } from '../functions/_shared/validation.ts';
import { followMergedInto, type AppUserRow } from '../functions/_shared/identity.ts';
import { ZodError } from 'zod';
import * as jose from 'jose';

function requestWithAuth(token: string): Request {
  return new Request('http://example.test/', {
    headers: { Authorization: `Bearer ${token}` },
  });
}

Deno.test('auth: JWT round-trip preserves claims', async () => {
  const canonicalKey = 'ck:_' + crypto.randomUUID().replaceAll('-', '');
  const installationId = crypto.randomUUID();
  const jwt = await issueSessionJWT({
    canonical_user_key: canonicalKey,
    installation_id: installationId,
    tier: 'premium',
  });

  const req = requestWithAuth(jwt);
  const claims = await verifySessionJWT(req);

  assertEquals(claims.canonical_user_key, canonicalKey);
  assertEquals(claims.installation_id, installationId);
  assertEquals(claims.tier, 'premium');
  assertEquals(claims.sub, canonicalKey);
  // exp should be ~now + default TTL.
  const now = Math.floor(Date.now() / 1000);
  const drift = Math.abs(claims.exp - (now + DEFAULT_JWT_TTL_SECONDS));
  // Allow 10s drift for CI execution time.
  if (drift > 10) throw new Error(`exp drift too large: ${drift}s`);
});

Deno.test('auth: missing Authorization → AuthError.reason=missing', async () => {
  const req = new Request('http://example.test/');
  await assertRejects(() => verifySessionJWT(req), AuthError, 'no Authorization header');
});

Deno.test('auth: non-Bearer header → AuthError.reason=malformed', async () => {
  const req = new Request('http://example.test/', {
    headers: { Authorization: 'Basic abc' },
  });
  const err = await assertRejects(() => verifySessionJWT(req), AuthError);
  assertEquals(err.reason, 'malformed');
});

Deno.test('auth: malformed token → AuthError.reason=malformed', async () => {
  const err = await assertRejects(
    () => verifySessionJWT(requestWithAuth('not.a.jwt')),
    AuthError,
  );
  assertEquals(err.reason, 'malformed');
});

// SCA-380: belt-and-suspenders re-validation of `installation_id`
// claim shape after JWT signature passes. Healthy mints (which all
// flow through `SessionBootstrapRequest`'s UUID v4 regex) never trip
// this — it's the rogue-mint backstop. Pin so a future refactor that
// drops the re-check fails loudly.
//
// SCA-410: `issueSessionJWT` now ALSO validates installation_id at mint
// time (matching the SCA-380 verify-side claim). Forging the JWT through
// our own minter therefore throws before signing — sign one directly via
// jose to bypass the mint-side guard and exercise the verify-side guard
// alone.
Deno.test('auth: rejects JWT whose installation_id claim is not a UUID v4', async () => {
  const canonicalKey = 'ck:_' + crypto.randomUUID().replaceAll('-', '');
  const secret = new TextEncoder().encode(Deno.env.get('STIR_JWT_SECRET') ?? '');
  const now = Math.floor(Date.now() / 1000);
  const jwt = await new jose.SignJWT({
    canonical_user_key: canonicalKey,
    installation_id: 'rogue-non-uuid-string',
    tier: 'free',
    role: 'authenticated',
  })
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setIssuer('stir-backend')
    .setAudience('authenticated')
    .setSubject(canonicalKey)
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(secret);

  const err = await assertRejects(() => verifySessionJWT(requestWithAuth(jwt)), AuthError);
  assertEquals(err.reason, 'malformed');
  assertEquals(err.message, 'installation_id claim is not a UUID v4');
});

// SCA-410: mint-side regex check on issueSessionJWT. Pin the throw so a
// future refactor that drops the guard surfaces in tests immediately.
Deno.test('auth: SCA-410 — issueSessionJWT throws on non-UUID installation_id', async () => {
  const canonicalKey = 'ck:_' + crypto.randomUUID().replaceAll('-', '');
  await assertRejects(
    () =>
      issueSessionJWT({
        canonical_user_key: canonicalKey,
        // deno-lint-ignore no-explicit-any
        installation_id: 'rogue-non-uuid-string' as any,
        tier: 'free',
      }),
    Error,
    'installation_id is not a UUID v4',
  );
});

// -------------------------------------------------------------------------
// Hashing
// -------------------------------------------------------------------------

Deno.test('hashing: canonical key hash is deterministic and 16 chars', async () => {
  const key = 'install:00000000-0000-0000-0000-000000000000';
  const a = await hashCanonicalKey(key);
  const b = await hashCanonicalKey(key);
  assertEquals(a, b);
  assertEquals(a.length, 16);
  assertEquals(/^[0-9a-f]{16}$/.test(a), true);
});

Deno.test('hashing: different keys produce different hashes', async () => {
  const a = await hashCanonicalKey('install:a');
  const b = await hashCanonicalKey('install:b');
  if (a === b) throw new Error('collision on trivial inputs');
});

// -------------------------------------------------------------------------
// Zod validation + field_errors adapter
// -------------------------------------------------------------------------

Deno.test('validation: rejects non-UUID installation_id with informative field_errors', () => {
  try {
    SessionBootstrapRequest.parse({
      installation_id: 'not-a-uuid',
      build: '1.0.0',
      os_version: '17',
    });
    throw new Error('should have rejected');
  } catch (err) {
    if (!(err instanceof ZodError)) throw err;
    const fieldErrors = zodToFieldErrors(err);
    const paths = fieldErrors.map((e) => e.field);
    assertEquals(paths.includes('installation_id'), true);
  }
});

Deno.test('validation: rejects extra unknown fields (.strict)', () => {
  assertThrows(
    () =>
      SessionBootstrapRequest.parse({
        installation_id: crypto.randomUUID(),
        build: '1.0.0',
        os_version: '17',
        extra_unknown_field: 'sneaky',
      }),
    ZodError,
  );
});

Deno.test('validation: accepts minimal valid install-only body', () => {
  const parsed = SessionBootstrapRequest.parse({
    installation_id: crypto.randomUUID(),
    build: '1.0.0',
    os_version: '17.5',
  });
  assertEquals(parsed.cloudkit_user_record_name, undefined);
});

// -------------------------------------------------------------------------
// followMergedInto — one-hop-max invariant
// -------------------------------------------------------------------------

function mockAppUser(overrides: Partial<AppUserRow>): AppUserRow {
  return {
    canonical_user_key: 'install:x',
    current_install_id: null,
    revenuecat_app_user_id: null,
    source_type: 'install',
    status: 'active',
    merged_into: null,
    created_at: new Date().toISOString(),
    last_seen_at: new Date().toISOString(),
    ...overrides,
  };
}

Deno.test('identity: followMergedInto returns active row as-is', async () => {
  const row = mockAppUser({ canonical_user_key: 'ck:abc', status: 'active' });
  // Fake client that we never call because merged_into is null.
  const fakeClient = {} as Parameters<typeof followMergedInto>[0];
  const result = await followMergedInto(fakeClient, row);
  assertEquals(result, row);
});

Deno.test('identity: followMergedInto throws on nested merge chain', async () => {
  const startRow = mockAppUser({
    canonical_user_key: 'install:a',
    merged_into: 'install:b',
    status: 'merged',
  });
  // Fake client returns a SECOND merged row when readAppUser is invoked.
  const hop = mockAppUser({
    canonical_user_key: 'install:b',
    merged_into: 'install:c',
    status: 'merged',
  });
  const fakeClient = {
    from() {
      return {
        select() {
          return {
            eq() {
              return {
                maybeSingle() {
                  return Promise.resolve({ data: hop, error: null });
                },
              };
            },
          };
        },
      };
    },
  } as unknown as Parameters<typeof followMergedInto>[0];

  await assertRejects(
    () => followMergedInto(fakeClient, startRow),
    Error,
    'nested merge',
  );
});
