// Step 8 — audit_log table schema + RLS + append-only posture.
//
// Verifies:
//   - admin SELECT via is_admin()
//   - authenticated non-admin sees empty
//   - iOS session JWT sees empty
//   - authenticated UPDATE/DELETE denied (RLS has no policy for those verbs)
//   - service role INSERT works

import { assertEquals, assertNotEquals } from '@std/assert';
import { clearRateLimitBuckets, serviceClient, userClient } from './_helpers/pg.ts';
import { seedAdmin, seedAuthOnlyUser } from './_helpers/admin_factory.ts';
import { quickBootstrap } from './_helpers/factory.ts';

await clearRateLimitBuckets();

function sampleEntry(over: Partial<Record<string, unknown>> = {}) {
  return {
    actor_id: null,
    actor_email: 'test@stir.app',
    action: 'test.sample',
    target_table: 'app_users',
    target_id: 'ck:test-' + crypto.randomUUID(),
    before_json: { status: 'active' },
    after_json: { status: 'banned' },
    request_id: crypto.randomUUID(),
    ...over,
  };
}

Deno.test('service role can INSERT audit_log rows', async () => {
  const svc = serviceClient();
  const { error } = await svc.from('audit_log').insert(sampleEntry());
  assertEquals(error, null);
});

Deno.test('admin can SELECT audit_log rows', async () => {
  const admin = await seedAdmin();
  const svc = serviceClient();

  const uniqueAction = `test.admin_select.${crypto.randomUUID()}`;
  await svc.from('audit_log').insert(sampleEntry({ action: uniqueAction }));

  const client = userClient(admin.jwt);
  const { data, error } = await client.from('audit_log').select('action').eq('action', uniqueAction);
  assertEquals(error, null);
  assertEquals((data ?? []).length, 1);
});

Deno.test('authenticated non-admin sees empty audit_log', async () => {
  const user = await seedAuthOnlyUser();
  const svc = serviceClient();

  await svc.from('audit_log').insert(sampleEntry({ action: 'test.non_admin.' + crypto.randomUUID() }));

  const client = userClient(user.jwt);
  const { data, error } = await client.from('audit_log').select('*');
  assertEquals(error, null);
  assertEquals((data ?? []).length, 0);
});

Deno.test('iOS session JWT sees empty audit_log', async () => {
  const session = await quickBootstrap();
  const svc = serviceClient();

  await svc.from('audit_log').insert(sampleEntry({ action: 'test.ios.' + crypto.randomUUID() }));

  const client = userClient(session.session_jwt);
  const { data } = await client.from('audit_log').select('*');
  assertEquals((data ?? []).length, 0);
});

Deno.test('admin authenticated UPDATE audit_log is denied (append-only)', async () => {
  const admin = await seedAdmin();
  const svc = serviceClient();

  const action = 'test.update_attempt.' + crypto.randomUUID();
  const { data: inserted } = await svc
    .from('audit_log')
    .insert(sampleEntry({ action }))
    .select('id')
    .single();
  assertNotEquals(inserted, null);

  const client = userClient(admin.jwt);
  // RLS update policy missing → 0 rows affected (PostgREST returns empty success).
  // Assert the row was NOT modified by re-reading via service role.
  await client
    .from('audit_log')
    .update({ action: 'hacked.new_action' })
    .eq('id', inserted!.id);

  const { data: after } = await svc
    .from('audit_log')
    .select('action')
    .eq('id', inserted!.id)
    .single();
  assertEquals(after?.action, action);
});

Deno.test('admin authenticated DELETE audit_log is denied (append-only)', async () => {
  const admin = await seedAdmin();
  const svc = serviceClient();

  const action = 'test.delete_attempt.' + crypto.randomUUID();
  const { data: inserted } = await svc
    .from('audit_log')
    .insert(sampleEntry({ action }))
    .select('id')
    .single();

  const client = userClient(admin.jwt);
  await client.from('audit_log').delete().eq('id', inserted!.id);

  const { data: after } = await svc
    .from('audit_log')
    .select('id')
    .eq('id', inserted!.id);
  assertEquals((after ?? []).length, 1, 'audit_log row must survive authenticated DELETE attempt');
});

Deno.test('CHECK: action length <= 128', async () => {
  const svc = serviceClient();
  const tooLong = 'x'.repeat(129);
  const { error } = await svc.from('audit_log').insert(sampleEntry({ action: tooLong }));
  assertEquals(error !== null, true);
});
