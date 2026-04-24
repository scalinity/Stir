// Step 8 Phase 2 — ops-admin router end-to-end.
//
// Exercises the Edge Function HTTP surface (not direct RPC) so the full
// stack is proven: verifyAdminAuth → Zod → RPC → writeAudit → jsonOk.

import './_helpers/env.ts';
import { assertEquals, assertNotEquals } from '@std/assert';
import { clearRateLimitBuckets, serviceClient } from './_helpers/pg.ts';
import { seedAdmin, seedAuthOnlyUser } from './_helpers/admin_factory.ts';
import { quickBootstrap } from './_helpers/factory.ts';

await clearRateLimitBuckets();

const FUNCTIONS_URL = Deno.env.get('SUPABASE_URL')
  ? `${Deno.env.get('SUPABASE_URL')}/functions/v1`
  : 'http://127.0.0.1:54321/functions/v1';

async function callOpsAdmin(
  body: unknown,
  authHeader: string | null,
): Promise<{ status: number; body: Record<string, unknown> }> {
  const headers: Record<string, string> = { 'content-type': 'application/json' };
  if (authHeader !== null) headers['Authorization'] = authHeader;
  const res = await fetch(`${FUNCTIONS_URL}/ops-admin`, {
    method: 'POST',
    headers,
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
  const parsed = await res.json();
  return { status: res.status, body: parsed };
}

// ---------------------------------------------------------------------------
// Auth gate
// ---------------------------------------------------------------------------

Deno.test('ops-admin: missing Authorization → 401 AUTH-01 reason=missing', async () => {
  const { status, body } = await callOpsAdmin({ action: 'users.list', params: {} }, null);
  assertEquals(status, 401);
  assertEquals(body.error, 'AUTH-01');
  assertEquals(body.reason, 'missing');
});

Deno.test('ops-admin: iOS session JWT → 401 AUTH-01 reason=wrong_issuer', async () => {
  const session = await quickBootstrap();
  const { status, body } = await callOpsAdmin(
    { action: 'users.list', params: {} },
    `Bearer ${session.session_jwt}`,
  );
  assertEquals(status, 401);
  assertEquals(body.error, 'AUTH-01');
  assertEquals(body.reason, 'wrong_issuer');
});

Deno.test('ops-admin: authenticated non-admin → 403 BILL-01 not_admin', async () => {
  const user = await seedAuthOnlyUser();
  const { status, body } = await callOpsAdmin(
    { action: 'users.list', params: {} },
    `Bearer ${user.jwt}`,
  );
  assertEquals(status, 403);
  assertEquals(body.error, 'BILL-01');
});

Deno.test('ops-admin: non-POST method → 405', async () => {
  const res = await fetch(`${FUNCTIONS_URL}/ops-admin`, { method: 'GET' });
  assertEquals(res.status, 405);
  const body = await res.json();
  assertEquals(body.error, 'METHOD-NOT-ALLOWED-01');
});

// ---------------------------------------------------------------------------
// Request validation
// ---------------------------------------------------------------------------

Deno.test('ops-admin: malformed JSON → VAL-01', async () => {
  const admin = await seedAdmin();
  const { status, body } = await callOpsAdmin('not-json', `Bearer ${admin.jwt}`);
  assertEquals(status, 400);
  assertEquals(body.error, 'VAL-01');
});

Deno.test('ops-admin: unknown action → VAL-01 (discriminated-union miss)', async () => {
  const admin = await seedAdmin();
  const { status, body } = await callOpsAdmin(
    { action: 'not_a_real_action', params: {} },
    `Bearer ${admin.jwt}`,
  );
  assertEquals(status, 400);
  assertEquals(body.error, 'VAL-01');
});

Deno.test('ops-admin: users.force_reauth missing canonical_user_key → VAL-01', async () => {
  const admin = await seedAdmin();
  const { status, body } = await callOpsAdmin(
    { action: 'users.force_reauth', params: {} },
    `Bearer ${admin.jwt}`,
  );
  assertEquals(status, 400);
  assertEquals(body.error, 'VAL-01');
});

// ---------------------------------------------------------------------------
// Action: users.list
// ---------------------------------------------------------------------------

Deno.test('ops-admin: users.list returns paginated users array', async () => {
  const admin = await seedAdmin();
  await Promise.all([quickBootstrap(), quickBootstrap()]);
  const { status, body } = await callOpsAdmin(
    { action: 'users.list', params: { limit: 100 } },
    `Bearer ${admin.jwt}`,
  );
  assertEquals(status, 200);
  assertEquals(body.ok, true);
  assertEquals(Array.isArray(body.users), true);
  assertEquals(typeof body.total_count, 'number');
  assertEquals((body.users as unknown[]).length >= 2, true);
});

Deno.test('ops-admin: users.list tier filter narrows', async () => {
  const admin = await seedAdmin();
  await quickBootstrap(); // seeds free tier
  const { status, body } = await callOpsAdmin(
    { action: 'users.list', params: { tier: 'pro', limit: 100 } },
    `Bearer ${admin.jwt}`,
  );
  assertEquals(status, 200);
  const users = body.users as Array<{ tier: string }>;
  for (const u of users) assertEquals(u.tier, 'pro');
});

// ---------------------------------------------------------------------------
// Action: users.force_reauth
// ---------------------------------------------------------------------------

Deno.test('ops-admin: users.force_reauth sets reauth_required_at + writes audit', async () => {
  const admin = await seedAdmin();
  const session = await quickBootstrap();

  const { status, body } = await callOpsAdmin(
    {
      action: 'users.force_reauth',
      params: { canonical_user_key: session.canonical_user_key },
    },
    `Bearer ${admin.jwt}`,
  );
  assertEquals(status, 200);
  assertEquals(body.ok, true);
  assertNotEquals(body.reauth_required_at, null);
  assertNotEquals(body.audit_id, null);

  // Verify DB state.
  const svc = serviceClient();
  const { data: row } = await svc
    .from('app_users')
    .select('reauth_required_at')
    .eq('canonical_user_key', session.canonical_user_key)
    .single();
  assertNotEquals(row?.reauth_required_at, null);

  // Verify audit row.
  const { data: audit } = await svc
    .from('audit_log')
    .select('actor_id, actor_email, action, target_table, target_id, after_json')
    .eq('id', body.audit_id as string)
    .single();
  assertEquals(audit?.action, 'users.force_reauth');
  assertEquals(audit?.actor_id, admin.authUserId);
  assertEquals(audit?.actor_email, admin.email);
  assertEquals(audit?.target_table, 'app_users');
  assertEquals(audit?.target_id, session.canonical_user_key);
});

Deno.test('ops-admin: users.force_reauth on non-existent user → VAL-01 404 (review W17)', async () => {
  const admin = await seedAdmin();
  const { status, body } = await callOpsAdmin(
    {
      action: 'users.force_reauth',
      params: { canonical_user_key: 'install:nope-' + crypto.randomUUID() },
    },
    `Bearer ${admin.jwt}`,
  );
  assertEquals(status, 404);
  assertEquals(body.error, 'VAL-01');
  assertEquals(String(body.message).includes('user not found'), true);
});
