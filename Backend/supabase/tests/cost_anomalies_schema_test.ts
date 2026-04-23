// Step 8 — cost_anomalies table + RLS tests.

import { assertEquals } from '@std/assert';
import { clearRateLimitBuckets, serviceClient, userClient } from './_helpers/pg.ts';
import { seedAdmin, seedAuthOnlyUser } from './_helpers/admin_factory.ts';

await clearRateLimitBuckets();

function sampleAnomaly(over: Partial<Record<string, unknown>> = {}) {
  return {
    canonical_user_key_hash: 'testhash_' + crypto.randomUUID().slice(0, 8),
    anomaly_type: 'daily_spend_2x',
    severity: 'warn',
    details_json: { tier: 'premium', spend_24h_usd: 3.25, call_count: 42 },
    ...over,
  };
}

Deno.test('service role INSERT works + enum values accepted', async () => {
  const svc = serviceClient();

  for (const type of [
    'daily_spend_2x',
    'daily_spend_hard_cap',
    'voice_session_tokens_over_cap',
    'runaway_session',
  ]) {
    const { error } = await svc.from('cost_anomalies').insert(sampleAnomaly({ anomaly_type: type }));
    assertEquals(error, null, `anomaly_type=${type} should insert cleanly`);
  }

  for (const sev of ['warn', 'critical']) {
    const { error } = await svc.from('cost_anomalies').insert(sampleAnomaly({ severity: sev }));
    assertEquals(error, null, `severity=${sev} should insert cleanly`);
  }
});

Deno.test('service role INSERT rejects invalid enum value', async () => {
  const svc = serviceClient();
  const { error } = await svc
    .from('cost_anomalies')
    .insert(sampleAnomaly({ anomaly_type: 'totally_bogus' }));
  assertEquals(error !== null, true);
});

Deno.test('admin SELECT cost_anomalies works', async () => {
  const admin = await seedAdmin();
  const svc = serviceClient();

  const uniqHash = 'testhash_admin_' + crypto.randomUUID().slice(0, 8);
  await svc.from('cost_anomalies').insert(sampleAnomaly({ canonical_user_key_hash: uniqHash }));

  const client = userClient(admin.jwt);
  const { data } = await client
    .from('cost_anomalies')
    .select('*')
    .eq('canonical_user_key_hash', uniqHash);
  assertEquals((data ?? []).length, 1);
});

Deno.test('non-admin authenticated sees empty cost_anomalies', async () => {
  const user = await seedAuthOnlyUser();
  const svc = serviceClient();

  const uniqHash = 'testhash_non_admin_' + crypto.randomUUID().slice(0, 8);
  await svc.from('cost_anomalies').insert(sampleAnomaly({ canonical_user_key_hash: uniqHash }));

  const client = userClient(user.jwt);
  const { data } = await client
    .from('cost_anomalies')
    .select('*')
    .eq('canonical_user_key_hash', uniqHash);
  assertEquals((data ?? []).length, 0);
});

Deno.test('admin UPDATE (e.g., resolve) allowed via RLS', async () => {
  const admin = await seedAdmin();
  const svc = serviceClient();

  const uniqHash = 'testhash_resolve_' + crypto.randomUUID().slice(0, 8);
  const { data: inserted } = await svc
    .from('cost_anomalies')
    .insert(sampleAnomaly({ canonical_user_key_hash: uniqHash }))
    .select('id')
    .single();

  const client = userClient(admin.jwt);
  const { error } = await client
    .from('cost_anomalies')
    .update({ resolved_at: new Date().toISOString(), resolved_by: admin.authUserId, resolution_notes: 'false alarm' })
    .eq('id', inserted!.id);
  assertEquals(error, null);

  const { data: after } = await svc
    .from('cost_anomalies')
    .select('resolved_at, resolution_notes')
    .eq('id', inserted!.id)
    .single();
  assertEquals(after?.resolution_notes, 'false alarm');
});

Deno.test('non-admin UPDATE denied (RLS is_admin() gate)', async () => {
  const user = await seedAuthOnlyUser();
  const svc = serviceClient();

  const uniqHash = 'testhash_no_update_' + crypto.randomUUID().slice(0, 8);
  const { data: inserted } = await svc
    .from('cost_anomalies')
    .insert(sampleAnomaly({ canonical_user_key_hash: uniqHash }))
    .select('id')
    .single();

  const client = userClient(user.jwt);
  await client.from('cost_anomalies').update({ resolution_notes: 'hacked' }).eq('id', inserted!.id);

  // Row unchanged.
  const { data: after } = await svc
    .from('cost_anomalies')
    .select('resolution_notes')
    .eq('id', inserted!.id)
    .single();
  assertEquals(after?.resolution_notes, null);
});
