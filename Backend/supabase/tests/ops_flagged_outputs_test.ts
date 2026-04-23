// Step 8 — ops_flagged_outputs schema + RLS tests.

import { assertEquals, assertStringIncludes } from '@std/assert';
import { clearRateLimitBuckets, serviceClient, userClient } from './_helpers/pg.ts';
import { seedAdmin, seedAuthOnlyUser } from './_helpers/admin_factory.ts';
import { quickBootstrap } from './_helpers/factory.ts';

await clearRateLimitBuckets();

function sampleFlag(over: Partial<Record<string, unknown>> = {}) {
  return {
    canonical_user_key_hash: 'deadbeefcafebabe',
    feature_key: 'substitution',
    request_id: crypto.randomUUID(),
    flagged_by: 'user',
    flag_reason: 'allergen leaked into suggestion',
    raw_input_json: { missing_ingredient: 'peanut butter' },
    raw_output_json: { substitution_text: 'almond butter' },
    ...over,
  };
}

Deno.test('RLS: authenticated non-admin cannot SELECT ops_flagged_outputs', async () => {
  const user = await seedAuthOnlyUser();
  const svc = serviceClient();

  // Seed a row as service role.
  await svc.from('ops_flagged_outputs').insert(sampleFlag());

  const client = userClient(user.jwt);
  const { data, error } = await client.from('ops_flagged_outputs').select('*');
  assertEquals(error, null);
  assertEquals((data ?? []).length, 0);
});

Deno.test('RLS: admin can SELECT ops_flagged_outputs', async () => {
  const admin = await seedAdmin();
  const svc = serviceClient();

  await svc.from('ops_flagged_outputs').insert(sampleFlag({ feature_key: 'cook_turn' }));

  const client = userClient(admin.jwt);
  const { data, error } = await client.from('ops_flagged_outputs').select('*').eq('feature_key', 'cook_turn');
  assertEquals(error, null);
  assertEquals((data ?? []).length >= 1, true);
});

Deno.test('RLS: iOS session JWT sees empty ops_flagged_outputs', async () => {
  const session = await quickBootstrap();
  const svc = serviceClient();

  await svc.from('ops_flagged_outputs').insert(sampleFlag({ feature_key: 'dinner_solve' }));

  const client = userClient(session.session_jwt);
  const { data, error } = await client.from('ops_flagged_outputs').select('*');
  assertEquals(error, null);
  assertEquals((data ?? []).length, 0);
});

Deno.test('CHECK: resolution consistency — unresolved row rejects resolution_action alone', async () => {
  const svc = serviceClient();

  // Insert unresolved
  const { data: inserted } = await svc
    .from('ops_flagged_outputs')
    .insert(sampleFlag({ request_id: crypto.randomUUID() }))
    .select('id')
    .single();

  // Try to set resolution_action without resolved_at → CHECK violation.
  const { error } = await svc
    .from('ops_flagged_outputs')
    .update({ resolution_action: 'dismissed' })
    .eq('id', inserted!.id);

  assertEquals(error !== null, true);
  // Postgres check-constraint violation carries specific SQLSTATE.
  assertStringIncludes(error!.message.toLowerCase(), 'ops_flagged_outputs_resolution_consistency');
});

Deno.test('CHECK: canned_fallback_pinned requires canned_fallback_json', async () => {
  const svc = serviceClient();
  const admin = await seedAdmin();

  const { data: inserted } = await svc
    .from('ops_flagged_outputs')
    .insert(sampleFlag({ request_id: crypto.randomUUID() }))
    .select('id')
    .single();

  // Resolve as canned_fallback_pinned WITHOUT canned_fallback_json → rejected.
  const { error: err1 } = await svc
    .from('ops_flagged_outputs')
    .update({
      resolved_at: new Date().toISOString(),
      resolved_by: admin.authUserId,
      resolution_action: 'canned_fallback_pinned',
      // canned_fallback_json omitted
    })
    .eq('id', inserted!.id);
  assertEquals(err1 !== null, true);

  // Same row, with canned_fallback_json, succeeds.
  const { error: err2 } = await svc
    .from('ops_flagged_outputs')
    .update({
      resolved_at: new Date().toISOString(),
      resolved_by: admin.authUserId,
      resolution_action: 'canned_fallback_pinned',
      canned_fallback_json: { substitution_text: 'safe canned' },
    })
    .eq('id', inserted!.id);
  assertEquals(err2, null);
});

Deno.test('CHECK: dismissed resolution with canned_fallback_json is rejected', async () => {
  const svc = serviceClient();
  const admin = await seedAdmin();

  const { data: inserted } = await svc
    .from('ops_flagged_outputs')
    .insert(sampleFlag({ request_id: crypto.randomUUID() }))
    .select('id')
    .single();

  const { error } = await svc
    .from('ops_flagged_outputs')
    .update({
      resolved_at: new Date().toISOString(),
      resolved_by: admin.authUserId,
      resolution_action: 'dismissed',
      canned_fallback_json: { should: 'not be here' },
    })
    .eq('id', inserted!.id);

  assertEquals(error !== null, true);
});

Deno.test('flag_reason 2000-char CHECK enforced', async () => {
  const svc = serviceClient();
  const tooLong = 'a'.repeat(2001);

  const { error } = await svc
    .from('ops_flagged_outputs')
    .insert(sampleFlag({ flag_reason: tooLong }));

  assertEquals(error !== null, true);
});
