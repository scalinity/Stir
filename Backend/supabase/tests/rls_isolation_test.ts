// RLS isolation tests.
//
// Bootstrap two distinct users, seed each user's rows via the service-role
// client, then read via PostgREST with each user's JWT. Asserts that
// cross-user reads return empty — NEVER 403. RLS is a row filter, not an
// access check; a user reading rows they can't see just gets nothing back.
//
// Also verifies the three ops-only tables (app_users, feature_flags,
// prompt_versions) return empty to any authenticated client — their RLS
// policies intentionally don't grant authenticated access, so service
// role is the only path in.

import { assertEquals } from '@std/assert';
import { quickBootstrap, testCkRecord, testInstallId } from './_helpers/factory.ts';
import { serviceClient, userClient } from './_helpers/pg.ts';

async function setupTwoUsers() {
  const userA = await quickBootstrap({ installation_id: testInstallId() });
  const userB = await quickBootstrap({ installation_id: testInstallId() });
  return { userA, userB };
}

Deno.test('RLS: usage_counters isolated per user', async () => {
  const { userA, userB } = await setupTwoUsers();

  const aClient = userClient(userA.session_jwt);
  const bClient = userClient(userB.session_jwt);

  // A sees its own rows (bootstrap already seeded 3).
  const { data: aRowsA } = await aClient.from('usage_counters').select('canonical_user_key');
  assertEquals((aRowsA ?? []).length, 3);
  for (const row of aRowsA ?? []) {
    assertEquals(row.canonical_user_key, userA.canonical_user_key);
  }

  // B sees its own rows.
  const { data: bRowsB } = await bClient.from('usage_counters').select('canonical_user_key');
  assertEquals((bRowsB ?? []).length, 3);

  // A filtering for B's key returns empty (NOT 403).
  const { data: aLookingAtB, error: aLookingErr } = await aClient
    .from('usage_counters')
    .select('*')
    .eq('canonical_user_key', userB.canonical_user_key);
  assertEquals(aLookingErr, null);
  assertEquals((aLookingAtB ?? []).length, 0);
});

Deno.test('RLS: entitlement_snapshots isolated per user', async () => {
  const { userA, userB } = await setupTwoUsers();

  const aClient = userClient(userA.session_jwt);
  const { data } = await aClient
    .from('entitlement_snapshots')
    .select('canonical_user_key');
  const keys = new Set((data ?? []).map((r: { canonical_user_key: string }) => r.canonical_user_key));
  assertEquals(keys.has(userA.canonical_user_key), true);
  assertEquals(keys.has(userB.canonical_user_key), false);
});

Deno.test('RLS: ai_request_log isolated per user', async () => {
  const { userA, userB } = await setupTwoUsers();

  // Seed both users with a log row via service-role.
  const admin = serviceClient();
  await admin.from('ai_request_log').insert([
    {
      request_id: `test-${crypto.randomUUID()}`,
      canonical_user_key: userA.canonical_user_key,
      feature_key: 'dinner_solve',
      model: 'gemini-3-flash',
      input_tokens: 100,
      output_tokens: 50,
      cost_usd: 0.001,
      latency_ms: 500,
    },
    {
      request_id: `test-${crypto.randomUUID()}`,
      canonical_user_key: userB.canonical_user_key,
      feature_key: 'dinner_solve',
      model: 'gemini-3-flash',
      input_tokens: 100,
      output_tokens: 50,
      cost_usd: 0.001,
      latency_ms: 500,
    },
  ]);

  const aClient = userClient(userA.session_jwt);
  const { data: aRows } = await aClient.from('ai_request_log').select('canonical_user_key');
  assertEquals((aRows ?? []).length, 1);
  assertEquals(aRows?.[0]?.canonical_user_key, userA.canonical_user_key);
});

Deno.test('RLS: device_installations isolated per user', async () => {
  const { userA, userB } = await setupTwoUsers();

  const aClient = userClient(userA.session_jwt);
  const { data } = await aClient.from('device_installations').select('canonical_user_key');
  assertEquals((data ?? []).length, 1);
  assertEquals(data?.[0]?.canonical_user_key, userA.canonical_user_key);
});

Deno.test('RLS: app_users denies all authenticated reads', async () => {
  const { userA } = await setupTwoUsers();
  const aClient = userClient(userA.session_jwt);
  const { data, error } = await aClient.from('app_users').select('canonical_user_key');
  // PostgREST returns success but 0 rows (no policy = default deny filter).
  assertEquals(error, null);
  assertEquals((data ?? []).length, 0);
});

Deno.test('RLS: feature_flags denies all authenticated reads', async () => {
  const { userA } = await setupTwoUsers();
  const aClient = userClient(userA.session_jwt);
  const { data, error } = await aClient.from('feature_flags').select('key');
  assertEquals(error, null);
  assertEquals((data ?? []).length, 0);
});

Deno.test('RLS: prompt_versions denies all authenticated reads', async () => {
  const { userA } = await setupTwoUsers();
  const aClient = userClient(userA.session_jwt);
  const { data, error } = await aClient.from('prompt_versions').select('feature_key');
  assertEquals(error, null);
  assertEquals((data ?? []).length, 0);
});

Deno.test('RLS: service_role bypasses RLS (sanity check)', async () => {
  // Sanity: verify the service-role client in our test helpers actually
  // bypasses RLS. If this ever fails, our RLS tests are meaningless.
  await quickBootstrap({ installation_id: testInstallId() });
  const admin = serviceClient();
  const { data } = await admin.from('feature_flags').select('key');
  assertEquals((data ?? []).length, 8);
});
