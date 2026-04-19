// Integration tests for GET /v1/config/bootstrap.
//
// Covers the happy path + all four AUTH-01 reason codes
// (missing | expired | malformed | signature_invalid).

import './_helpers/env.ts';
import { assertEquals, assertExists } from '@std/assert';
import * as jose from 'jose';
import { callConfigBootstrap, quickBootstrap } from './_helpers/factory.ts';

const JWT_SECRET = new TextEncoder().encode(
  Deno.env.get('STIR_JWT_SECRET') ?? 'super-secret-jwt-token-with-at-least-32-characters-long',
);

Deno.test('config-bootstrap: happy path returns entitlements + flags + prompts', async () => {
  const session = await quickBootstrap();
  const res = await callConfigBootstrap(session.session_jwt);
  assertEquals(res.status, 200);

  const body = res.body as {
    entitlements: { tier: string; quotas: unknown[] };
    feature_flags: unknown[];
    prompts: Array<{ feature_key: string; version: string }>;
  };

  assertEquals(body.entitlements.tier, 'free');
  assertEquals(body.entitlements.quotas.length, 3);
  assertEquals(body.feature_flags.length, 8);
  assertEquals(body.prompts.length, 7);

  const keys = new Set(body.prompts.map((p) => p.feature_key));
  for (const expected of [
    'pantry_parse',
    'dinner_solve',
    'cook_turn',
    'cook_mode_realtime',
    'substitution',
    'recipe_import',
    'grocery_generate',
  ]) {
    assertEquals(keys.has(expected), true, `prompts missing ${expected}`);
  }
  // Step 3 promoted pantry_parse + dinner_solve to v1.0.0; others stay
  // at the step-1 v0.0.0 placeholders.
  const promotedInStep3 = new Set(['pantry_parse', 'dinner_solve']);
  for (const p of body.prompts) {
    const expected = promotedInStep3.has(p.feature_key) ? '1.0.0' : '0.0.0';
    assertEquals(p.version, expected, `unexpected version for ${p.feature_key}`);
  }
});

Deno.test('config-bootstrap: AUTH-01 reason=missing when no Authorization header', async () => {
  const res = await callConfigBootstrap(null);
  assertEquals(res.status, 401);
  const body = res.body as { error: string; reason: string };
  assertEquals(body.error, 'AUTH-01');
  assertEquals(body.reason, 'missing');
});

Deno.test('config-bootstrap: AUTH-01 reason=malformed on non-JWT Bearer', async () => {
  const res = await callConfigBootstrap('not-a-jwt');
  assertEquals(res.status, 401);
  const body = res.body as { error: string; reason: string };
  assertEquals(body.error, 'AUTH-01');
  assertEquals(body.reason, 'malformed');
});

Deno.test('config-bootstrap: AUTH-01 reason=expired on past-exp JWT', async () => {
  // Mint a JWT that expired 1 hour ago using the production secret.
  const now = Math.floor(Date.now() / 1000);
  const expired = await new jose.SignJWT({
    canonical_user_key: 'install:00000000-0000-0000-0000-000000000000',
    installation_id: '00000000-0000-0000-0000-000000000000',
    tier: 'free',
    role: 'authenticated',
  })
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setIssuer('stir-backend')
    .setAudience('authenticated')
    .setSubject('install:00000000-0000-0000-0000-000000000000')
    .setIssuedAt(now - 7200)
    .setExpirationTime(now - 3600)
    .sign(JWT_SECRET);

  const res = await callConfigBootstrap(expired);
  assertEquals(res.status, 401);
  const body = res.body as { error: string; reason: string };
  assertEquals(body.error, 'AUTH-01');
  assertEquals(body.reason, 'expired');
});

Deno.test('config-bootstrap: AUTH-01 reason=signature_invalid on wrong-secret JWT', async () => {
  const wrongSecret = new TextEncoder().encode('a-different-secret-thats-at-least-32-chars-long');
  const now = Math.floor(Date.now() / 1000);
  const forged = await new jose.SignJWT({
    canonical_user_key: 'install:00000000-0000-0000-0000-000000000000',
    installation_id: '00000000-0000-0000-0000-000000000000',
    tier: 'free',
    role: 'authenticated',
  })
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setIssuer('stir-backend')
    .setAudience('authenticated')
    .setSubject('install:00000000-0000-0000-0000-000000000000')
    .setIssuedAt(now)
    .setExpirationTime(now + 86400)
    .sign(wrongSecret);

  const res = await callConfigBootstrap(forged);
  assertEquals(res.status, 401);
  const body = res.body as { error: string; reason: string };
  assertEquals(body.error, 'AUTH-01');
  assertEquals(body.reason, 'signature_invalid');
});

Deno.test('config-bootstrap: response shape matches bootstrap entitlements (minus session fields)', async () => {
  const bs = await quickBootstrap();
  const res = await callConfigBootstrap(bs.session_jwt);
  assertEquals(res.status, 200);
  const body = res.body as { entitlements: Record<string, unknown> };

  // Field parity with bootstrap.entitlements.
  assertExists(body.entitlements.tier);
  assertExists(body.entitlements.billing_state);
  assertExists(body.entitlements.quotas);
  assertEquals(typeof body.entitlements.is_trial, 'boolean');
  assertEquals(typeof body.entitlements.voice_enabled, 'boolean');
  assertEquals(typeof body.entitlements.billing_retry_banner, 'boolean');
});
