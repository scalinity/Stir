// Integration tests for POST /v1/session/bootstrap.
//
// Requires: `supabase start` + `supabase functions serve --env-file .env`
// running locally. Tests hit real HTTP and a real Postgres through the
// service-role client for verification. `supabase db reset` fresh-starts.

import { assertEquals, assertExists } from '@std/assert';
import {
  callBootstrap,
  quickBootstrap,
  testCkRecord,
  testInstallId,
} from './_helpers/factory.ts';
import { clearRateLimitBuckets, serviceClient } from './_helpers/pg.ts';

// Kong in local dev overrides x-real-ip unconditionally, so every test
// in this file lands in one ip:bootstrap_hourly bucket and trips the
// 20/hr cap. Clear the bucket table once before any Deno.test runs.
await clearRateLimitBuckets();

Deno.test('session-bootstrap: happy path install-only', async () => {
  const installId = testInstallId();
  const res = await quickBootstrap({ installation_id: installId });

  assertEquals(res.canonical_user_key, `install:${installId}`);
  assertEquals(res.is_new_user, true);
  assertEquals(res.entitlements.tier, 'free');
  assertEquals(res.entitlements.billing_state, 'none');
  assertEquals(res.entitlements.voice_enabled, false);
  assertEquals(res.entitlements.billing_retry_banner, false);
  assertEquals(res.entitlements.quotas.length, 3);

  const byKey = new Map(res.entitlements.quotas.map((q) => [q.feature_key, q]));
  assertEquals(byKey.get('dinner_solve')?.cap, 6);
  assertEquals(byKey.get('dinner_solve')?.used, 0);
  assertEquals(byKey.get('voice_cook_session')?.cap, 0);
  assertEquals(byKey.get('recipe_import')?.cap, 2);

  // Every server flag seeded should appear. Count tracks every
  // ON CONFLICT-idempotent seed migration; bump when a new seed lands.
  assertEquals(res.feature_flags.length, 9);
  assertExists(res.session_jwt);
});

Deno.test('session-bootstrap: happy path CloudKit-first', async () => {
  const ck = testCkRecord();
  const res = await quickBootstrap({
    installation_id: testInstallId(),
    cloudkit_user_record_name: ck,
  });

  assertEquals(res.canonical_user_key, `ck:${ck}`);
  assertEquals(res.is_new_user, true);
});

Deno.test('session-bootstrap: alias forward install → ck', async () => {
  const installId = testInstallId();
  const ck = testCkRecord();

  // 1st call: install-only → creates install row.
  const first = await quickBootstrap({ installation_id: installId });
  assertEquals(first.canonical_user_key, `install:${installId}`);
  assertEquals(first.is_new_user, true);

  // 2nd call: install+ck on same install_id → should alias-forward.
  const second = await quickBootstrap({
    installation_id: installId,
    cloudkit_user_record_name: ck,
  });
  assertEquals(second.canonical_user_key, `ck:${ck}`);
  // is_new_user=true only when aliasing did NOT happen; here it did.
  assertEquals(second.is_new_user, false);

  // Verify DB state: install row merged_into set, status='merged'.
  const client = serviceClient();
  const { data: installRow } = await client
    .from('app_users')
    .select('status, merged_into')
    .eq('canonical_user_key', `install:${installId}`)
    .single();
  assertEquals(installRow?.status, 'merged');
  assertEquals(installRow?.merged_into, `ck:${ck}`);

  const { data: ckRow } = await client
    .from('app_users')
    .select('status, merged_into')
    .eq('canonical_user_key', `ck:${ck}`)
    .single();
  assertEquals(ckRow?.status, 'active');
  assertEquals(ckRow?.merged_into, null);

  // device_installations now owned by ck.
  const { data: deviceRow } = await client
    .from('device_installations')
    .select('canonical_user_key')
    .eq('installation_id', installId)
    .single();
  assertEquals(deviceRow?.canonical_user_key, `ck:${ck}`);
});

Deno.test('session-bootstrap: alias forward sums usage counters', async () => {
  const installId = testInstallId();
  const ck = testCkRecord();

  // Step 1: create install via bootstrap, then seed it with 3 dinner_solves.
  const first = await quickBootstrap({ installation_id: installId });
  const installKey = first.canonical_user_key;

  const client = serviceClient();
  const { error: updateErr } = await client
    .from('usage_counters')
    .update({ used_count: 3 })
    .eq('canonical_user_key', installKey)
    .eq('feature_key', 'dinner_solve');
  if (updateErr) throw updateErr;

  // Step 2: bootstrap install+ck → alias forward should sum.
  const second = await quickBootstrap({
    installation_id: installId,
    cloudkit_user_record_name: ck,
  });
  assertEquals(second.canonical_user_key, `ck:${ck}`);

  const ckDinnerQuota = second.entitlements.quotas.find((q) => q.feature_key === 'dinner_solve');
  assertEquals(ckDinnerQuota?.used, 3, 'ck row should carry the merged usage');
  assertEquals(ckDinnerQuota?.cap, 6);

  // Install row counters should be gone.
  const { data: leftover } = await client
    .from('usage_counters')
    .select('used_count')
    .eq('canonical_user_key', installKey);
  assertEquals(leftover?.length, 0, 'install usage_counters rows should be deleted');
});

Deno.test('session-bootstrap: alias forward with collision sums without clamping', async () => {
  const installId = testInstallId();
  const ck = testCkRecord();

  // Seed install row with 3 dinner_solves.
  const installBootstrap = await quickBootstrap({ installation_id: installId });
  const client = serviceClient();
  await client
    .from('usage_counters')
    .update({ used_count: 3 })
    .eq('canonical_user_key', installBootstrap.canonical_user_key)
    .eq('feature_key', 'dinner_solve');

  // Pre-seed a ck row for the same (period, feature) with used_count=4.
  // This simulates a re-install scenario where the ck identity accumulated
  // independently before the alias takes effect.
  const { periodStart } = {
    periodStart: installBootstrap.entitlements.quotas[0]?.period_end
      ? null
      : null,
  };
  // Read the actual period_start from the install row to match.
  const { data: installRows } = await client
    .from('usage_counters')
    .select('period_start, cap_count, tier_at_snapshot')
    .eq('canonical_user_key', installBootstrap.canonical_user_key)
    .eq('feature_key', 'dinner_solve')
    .single();

  const ckKey = `ck:${ck}`;
  // Create ck app_users row before seeding its counters (FK).
  await client.from('app_users').insert({
    canonical_user_key: ckKey,
    current_install_id: installId,
    revenuecat_app_user_id: ckKey,
    source_type: 'cloudkit',
    status: 'active',
  });
  await client.from('usage_counters').insert({
    canonical_user_key: ckKey,
    period_start: installRows!.period_start,
    feature_key: 'dinner_solve',
    used_count: 4,
    cap_count: installRows!.cap_count,
    tier_at_snapshot: installRows!.tier_at_snapshot,
  });

  // Bootstrap install+ck → should sum 3 + 4 = 7 (above the 6 Free cap).
  const second = await quickBootstrap({
    installation_id: installId,
    cloudkit_user_record_name: ck,
  });
  const ckDinner = second.entitlements.quotas.find((q) => q.feature_key === 'dinner_solve');
  assertEquals(ckDinner?.used, 7, 'summed usage should not be clamped to cap');
  assertEquals(ckDinner?.cap, 6, 'cap remains at Free-tier snapshot');
});

Deno.test('session-bootstrap: re-bootstrap same install_id is idempotent', async () => {
  const installId = testInstallId();
  const first = await quickBootstrap({ installation_id: installId, build: '1.0.0 (1)' });
  assertEquals(first.is_new_user, true);

  const second = await quickBootstrap({ installation_id: installId, build: '1.0.0 (2)' });
  assertEquals(second.canonical_user_key, first.canonical_user_key);
  assertEquals(second.is_new_user, false);

  // Build should have updated on device_installations.
  const client = serviceClient();
  const { data: deviceRow } = await client
    .from('device_installations')
    .select('build')
    .eq('installation_id', installId)
    .single();
  assertEquals(deviceRow?.build, '1.0.0 (2)');
});

// -------------------------------------------------------------------------
// VAL-01 rejection cases
// -------------------------------------------------------------------------

Deno.test('session-bootstrap: VAL-01 on missing installation_id', async () => {
  const res = await callBootstrap({ build: '1.0.0', os_version: '17' });
  assertEquals(res.status, 400);
  const body = res.body as unknown as { error: string; field_errors: unknown[] };
  assertEquals(body.error, 'VAL-01');
  assertEquals(Array.isArray(body.field_errors), true);
});

Deno.test('session-bootstrap: VAL-01 on non-UUID installation_id', async () => {
  const res = await callBootstrap({
    installation_id: 'not-a-uuid',
    build: '1.0.0',
    os_version: '17',
  });
  assertEquals(res.status, 400);
  const body = res.body as unknown as {
    error: string;
    field_errors: Array<{ field: string }>;
  };
  assertEquals(body.error, 'VAL-01');
  assertEquals(body.field_errors[0]?.field, 'installation_id');
});

Deno.test('session-bootstrap: VAL-01 on missing build', async () => {
  const res = await callBootstrap({ installation_id: testInstallId(), os_version: '17' });
  assertEquals(res.status, 400);
  assertEquals((res.body as { error: string }).error, 'VAL-01');
});

Deno.test('session-bootstrap: VAL-01 on oversized build string', async () => {
  const res = await callBootstrap({
    installation_id: testInstallId(),
    build: 'x'.repeat(65), // max is 64
    os_version: '17',
  });
  assertEquals(res.status, 400);
  assertEquals((res.body as { error: string }).error, 'VAL-01');
});

Deno.test('session-bootstrap: VAL-01 on invalid JSON body', async () => {
  const res = await callBootstrap('{not json');
  assertEquals(res.status, 400);
  assertEquals((res.body as { error: string }).error, 'VAL-01');
});

// SA2 regression: banned user is rejected with BILL-01 BEFORE alias-forward
// mutations run. Blocks two attacks:
//   1. Banned CK row receiving install-scoped data via the merge.
//   2. Install row being merged into a banned CK and left unrecoverable
//      (merged_into is terminal; un-merging isn't supported).
Deno.test('session-bootstrap: banned ck row rejects BEFORE alias-forward runs', async () => {
  const installId = testInstallId();
  const ck = testCkRecord();
  const client = serviceClient();

  // 1. Bootstrap the install-only user. Gives us an install row + counters.
  const first = await quickBootstrap({ installation_id: installId });
  const installKey = first.canonical_user_key;

  // 2. Seed some usage that a merge WOULD move if it ran.
  await client
    .from('usage_counters')
    .update({ used_count: 2 })
    .eq('canonical_user_key', installKey)
    .eq('feature_key', 'dinner_solve');

  // 3. Create the CK row in `banned` status out-of-band.
  const { error: insertErr } = await client.from('app_users').insert({
    canonical_user_key: `ck:${ck}`,
    source_type: 'cloudkit',
    revenuecat_app_user_id: `ck:${ck}`,
    status: 'banned',
  });
  if (insertErr) throw insertErr;

  // 4. Bootstrap install+ck. Expect BILL-01 403, NOT a merge.
  const res = await callBootstrap({
    installation_id: installId,
    cloudkit_user_record_name: ck,
    build: '1.0.0',
    os_version: '17',
  });
  assertEquals(res.status, 403);
  assertEquals((res.body as { error: string }).error, 'BILL-01');

  // 5. Verify NO merge happened. Install row still active, counters intact.
  const { data: installRow } = await client
    .from('app_users')
    .select('status, merged_into')
    .eq('canonical_user_key', installKey)
    .single();
  assertEquals(installRow?.status, 'active', 'install must NOT be merged into banned ck');
  assertEquals(installRow?.merged_into, null);

  const { data: installCounter } = await client
    .from('usage_counters')
    .select('used_count')
    .eq('canonical_user_key', installKey)
    .eq('feature_key', 'dinner_solve')
    .single();
  assertEquals(installCounter?.used_count, 2, 'install counters must not leak to banned ck');
});

Deno.test('session-bootstrap: banned install-only user rejects with BILL-01', async () => {
  const installId = testInstallId();
  const client = serviceClient();

  // Bootstrap once to create the row.
  await quickBootstrap({ installation_id: installId });

  // Flip status to banned out-of-band.
  const { error: updateErr } = await client
    .from('app_users')
    .update({ status: 'banned' })
    .eq('canonical_user_key', `install:${installId}`);
  if (updateErr) throw updateErr;

  // Next bootstrap should 403 without issuing a session JWT.
  const res = await callBootstrap({
    installation_id: installId,
    build: '1.0.0',
    os_version: '17',
  });
  assertEquals(res.status, 403);
  const body = res.body as { error: string; state?: string };
  assertEquals(body.error, 'BILL-01');
  assertEquals(body.state, 'banned');
});
