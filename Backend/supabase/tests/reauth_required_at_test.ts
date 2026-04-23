// Step 8 — app_users.reauth_required_at column (schema-only portion).
//
// Verifies the column exists, defaults NULL, and accepts timestamp writes
// from the service role. Enforcement (verifySessionJWT check + admin
// force_reauth route) lands in Phase 2 of step 8; that integration test
// ships with the admin route.

import { assertEquals, assertNotEquals } from '@std/assert';
import { clearRateLimitBuckets, serviceClient } from './_helpers/pg.ts';
import { quickBootstrap } from './_helpers/factory.ts';

await clearRateLimitBuckets();

Deno.test('app_users.reauth_required_at defaults NULL on fresh bootstrap', async () => {
  const session = await quickBootstrap();
  const client = serviceClient();

  const { data, error } = await client
    .from('app_users')
    .select('canonical_user_key, reauth_required_at')
    .eq('canonical_user_key', session.canonical_user_key)
    .single();

  assertEquals(error, null);
  assertNotEquals(data, null);
  assertEquals(data?.reauth_required_at, null);
});

Deno.test('app_users.reauth_required_at accepts TIMESTAMPTZ writes via service role', async () => {
  const session = await quickBootstrap();
  const client = serviceClient();
  const stamp = new Date().toISOString();

  const { error: updateErr } = await client
    .from('app_users')
    .update({ reauth_required_at: stamp })
    .eq('canonical_user_key', session.canonical_user_key);
  assertEquals(updateErr, null);

  const { data } = await client
    .from('app_users')
    .select('reauth_required_at')
    .eq('canonical_user_key', session.canonical_user_key)
    .single();
  // Postgres normalizes to UTC; just assert non-null + parseable.
  assertNotEquals(data?.reauth_required_at, null);
  const parsed = new Date(data!.reauth_required_at as string).getTime();
  assertEquals(isNaN(parsed), false);
});
