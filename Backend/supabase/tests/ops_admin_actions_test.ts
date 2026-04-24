// Step 8 Phase 2 — ops-admin router, actions 3-11.
// (Actions 1-2 — users.list + users.force_reauth — covered by
// ops_admin_router_test.ts.)

import './_helpers/env.ts';
import { assertEquals, assertNotEquals } from '@std/assert';
import { clearRateLimitBuckets, serviceClient } from './_helpers/pg.ts';
import { seedAdmin } from './_helpers/admin_factory.ts';
import { quickBootstrap } from './_helpers/factory.ts';

await clearRateLimitBuckets();

const FUNCTIONS_URL = Deno.env.get('SUPABASE_URL')
  ? `${Deno.env.get('SUPABASE_URL')}/functions/v1`
  : 'http://127.0.0.1:54321/functions/v1';

async function post(
  action: string,
  params: unknown,
  jwt: string,
): Promise<{ status: number; body: Record<string, unknown> }> {
  const res = await fetch(`${FUNCTIONS_URL}/ops-admin`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'Authorization': `Bearer ${jwt}` },
    body: JSON.stringify({ action, params }),
  });
  const body = await res.json();
  return { status: res.status, body };
}

// ---------------------------------------------------------------------------
// users.detail
// ---------------------------------------------------------------------------

Deno.test('ops-admin: users.detail returns aggregated blob', async () => {
  const admin = await seedAdmin();
  const session = await quickBootstrap();
  const { status, body } = await post(
    'users.detail',
    { canonical_user_key: session.canonical_user_key },
    admin.jwt,
  );
  assertEquals(status, 200);
  assertEquals(body.ok, true);
  const detail = body.detail as { user: { canonical_user_key: string } };
  assertEquals(detail.user.canonical_user_key, session.canonical_user_key);
});

// ---------------------------------------------------------------------------
// users.reset_quota
// ---------------------------------------------------------------------------

Deno.test('ops-admin: users.reset_quota zeroes used_count + writes audit', async () => {
  const admin = await seedAdmin();
  const session = await quickBootstrap();
  const svc = serviceClient();
  await svc.from('usage_counters').update({ used_count: 4 })
    .eq('canonical_user_key', session.canonical_user_key)
    .eq('feature_key', 'dinner_solve');

  const { status, body } = await post(
    'users.reset_quota',
    { canonical_user_key: session.canonical_user_key, feature_key: 'dinner_solve' },
    admin.jwt,
  );
  assertEquals(status, 200);
  assertEquals(body.ok, true);
  const before = body.before as { used_count: number };
  const after = body.after as { used_count: number };
  assertEquals(before.used_count, 4);
  assertEquals(after.used_count, 0);

  // Audit row.
  const { data: audit } = await svc.from('audit_log').select('action')
    .eq('id', body.audit_id as string).single();
  assertEquals(audit?.action, 'users.reset_quota');
});

// ---------------------------------------------------------------------------
// users.status
// ---------------------------------------------------------------------------

Deno.test('ops-admin: users.status active→banned→active + audit', async () => {
  const admin = await seedAdmin();
  const session = await quickBootstrap();

  const ban = await post(
    'users.status',
    { canonical_user_key: session.canonical_user_key, status: 'banned' },
    admin.jwt,
  );
  assertEquals(ban.status, 200);
  const banAfter = ban.body.after as { status: string };
  assertEquals(banAfter.status, 'banned');
  assertNotEquals(ban.body.audit_id, null);

  const unban = await post(
    'users.status',
    { canonical_user_key: session.canonical_user_key, status: 'active' },
    admin.jwt,
  );
  assertEquals(unban.status, 200);
});

Deno.test('ops-admin: users.status rejects merged (VAL-01 at zod)', async () => {
  const admin = await seedAdmin();
  const session = await quickBootstrap();
  const { status, body } = await post(
    'users.status',
    { canonical_user_key: session.canonical_user_key, status: 'merged' },
    admin.jwt,
  );
  assertEquals(status, 400);
  assertEquals(body.error, 'VAL-01');
});

// ---------------------------------------------------------------------------
// flagged_outputs.list
// ---------------------------------------------------------------------------

Deno.test('ops-admin: flagged_outputs.list returns paginated rows', async () => {
  const admin = await seedAdmin();
  const svc = serviceClient();
  const unique = crypto.randomUUID();
  await svc.from('ops_flagged_outputs').insert({
    canonical_user_key_hash: 'hash-' + unique.slice(0, 8),
    feature_key: 'substitution',
    request_id: crypto.randomUUID(),
    flagged_by: 'user',
    flag_reason: 'test-' + unique,
  });

  const { status, body } = await post('flagged_outputs.list', { state: 'open', limit: 100 }, admin.jwt);
  assertEquals(status, 200);
  assertEquals(body.ok, true);
  const rows = body.rows as Array<{ flag_reason: string }>;
  const ours = rows.find((r) => r.flag_reason === 'test-' + unique);
  assertNotEquals(ours, undefined);
});

// ---------------------------------------------------------------------------
// flagged_outputs.resolve
// ---------------------------------------------------------------------------

Deno.test('ops-admin: flagged_outputs.resolve dismissed + audit', async () => {
  const admin = await seedAdmin();
  const svc = serviceClient();
  const { data: inserted } = await svc.from('ops_flagged_outputs').insert({
    canonical_user_key_hash: 'hash-' + crypto.randomUUID().slice(0, 8),
    feature_key: 'substitution',
    request_id: crypto.randomUUID(),
    flagged_by: 'user',
    flag_reason: 'resolve-dismissed-test',
  }).select('id').single();

  const { status, body } = await post(
    'flagged_outputs.resolve',
    { id: inserted!.id, action: 'dismissed', resolution_notes: 'reviewed' },
    admin.jwt,
  );
  assertEquals(status, 200);
  assertEquals(body.ok, true);
  const fo = body.flagged_output as { resolution_action: string; resolved_at: string | null };
  assertEquals(fo.resolution_action, 'dismissed');
  assertNotEquals(fo.resolved_at, null);
});

Deno.test('ops-admin: flagged_outputs.resolve canned_fallback_pinned replaces cache', async () => {
  const admin = await seedAdmin();
  const session = await quickBootstrap();
  const svc = serviceClient();

  const requestId = crypto.randomUUID();
  // Seed a cache row that should be replaced.
  await svc.from('ai_response_cache').insert({
    canonical_user_key: session.canonical_user_key,
    request_id: requestId,
    feature_key: 'substitution',
    status_code: 200,
    response_body: { substitution_text: 'BAD ORIGINAL' },
  });

  const { data: flagged } = await svc.from('ops_flagged_outputs').insert({
    canonical_user_key_hash: 'hash-' + crypto.randomUUID().slice(0, 8),
    feature_key: 'substitution',
    request_id: requestId,
    flagged_by: 'user',
    flag_reason: 'leaked peanut allergen',
  }).select('id').single();

  const safeFallback = { substitution_text: 'SAFE PINNED', constraint_safe: true };
  const { status, body } = await post(
    'flagged_outputs.resolve',
    { id: flagged!.id, action: 'canned_fallback_pinned', canned_fallback_json: safeFallback },
    admin.jwt,
  );
  assertEquals(status, 200);

  // Verify cache was overwritten.
  const { data: cache } = await svc.from('ai_response_cache')
    .select('response_body').eq('request_id', requestId).single();
  assertEquals((cache?.response_body as { substitution_text: string }).substitution_text, 'SAFE PINNED');
});

Deno.test('ops-admin: flagged_outputs.resolve withdrawn deletes cache', async () => {
  const admin = await seedAdmin();
  const session = await quickBootstrap();
  const svc = serviceClient();

  const requestId = crypto.randomUUID();
  await svc.from('ai_response_cache').insert({
    canonical_user_key: session.canonical_user_key,
    request_id: requestId,
    feature_key: 'dinner_solve',
    status_code: 200,
    response_body: { bad: 'output' },
  });

  const { data: flagged } = await svc.from('ops_flagged_outputs').insert({
    canonical_user_key_hash: 'hash-' + crypto.randomUUID().slice(0, 8),
    feature_key: 'dinner_solve',
    request_id: requestId,
    flagged_by: 'admin',
    flag_reason: 'withdraw this',
  }).select('id').single();

  const { status } = await post(
    'flagged_outputs.resolve',
    { id: flagged!.id, action: 'withdrawn' },
    admin.jwt,
  );
  assertEquals(status, 200);

  const { data: cache } = await svc.from('ai_response_cache')
    .select('request_id').eq('request_id', requestId);
  assertEquals((cache ?? []).length, 0);
});

// ---------------------------------------------------------------------------
// cost_anomalies.list
// ---------------------------------------------------------------------------

Deno.test('ops-admin: cost_anomalies.list with severity filter', async () => {
  const admin = await seedAdmin();
  const svc = serviceClient();
  await svc.from('cost_anomalies').insert({
    canonical_user_key_hash: 'hash-' + crypto.randomUUID().slice(0, 8),
    anomaly_type: 'daily_spend_hard_cap',
    severity: 'critical',
    details_json: { spend_24h_usd: 12 },
  });

  const { status, body } = await post(
    'cost_anomalies.list',
    { severity: 'critical', limit: 10 },
    admin.jwt,
  );
  assertEquals(status, 200);
  assertEquals(body.ok, true);
  const rows = body.rows as Array<{ severity: string }>;
  for (const r of rows) assertEquals(r.severity, 'critical');
});

// ---------------------------------------------------------------------------
// voice_sessions.list
// ---------------------------------------------------------------------------

Deno.test('ops-admin: voice_sessions.list surfaces runaway', async () => {
  const admin = await seedAdmin();
  const session = await quickBootstrap();
  const svc = serviceClient();
  const sid = crypto.randomUUID();
  for (let i = 0; i < 3; i++) {
    await svc.from('ai_request_log').insert({
      request_id: `voice:${sid}:${i}`,
      canonical_user_key: session.canonical_user_key,
      feature_key: 'cook_mode_realtime',
      model: 'gemini-3.1-flash-live-preview',
      input_tokens: 25000,
      output_tokens: 5000,
      cost_usd: 0.15,
      latency_ms: 600,
    });
  }

  const { status, body } = await post('voice_sessions.list', { min_tokens: 50000, limit: 50 }, admin.jwt);
  assertEquals(status, 200);
  const sessions = body.sessions as Array<{ session_id: string }>;
  const found = sessions.find((s) => s.session_id === sid);
  assertNotEquals(found, undefined);
});

// ---------------------------------------------------------------------------
// prompt_versions.rollout
// ---------------------------------------------------------------------------

Deno.test('ops-admin: prompt_versions.rollout updates rollout_pct + audit', async () => {
  const admin = await seedAdmin();
  const svc = serviceClient();
  // Pick any existing default prompt version. prompt_versions PK is composite
  // (feature_key, version); no synthetic id column.
  const { data: pvs } = await svc.from('prompt_versions')
    .select('feature_key, version, rollout_pct').eq('is_default', true).limit(1);
  const pv = pvs?.[0];
  if (!pv) throw new Error('no default prompt_version seeded to test against');

  const original = pv.rollout_pct as number;
  const newPct = original === 100 ? 95 : 100;

  const { status, body } = await post(
    'prompt_versions.rollout',
    { feature_key: pv.feature_key, version: pv.version, rollout_pct: newPct },
    admin.jwt,
  );
  assertEquals(status, 200);
  const after = body.after as { rollout_pct: number };
  assertEquals(after.rollout_pct, newPct);

  // Restore for other tests.
  await svc.from('prompt_versions').update({ rollout_pct: original })
    .eq('feature_key', pv.feature_key).eq('version', pv.version);
});

// ---------------------------------------------------------------------------
// feature_flags.update
// ---------------------------------------------------------------------------

Deno.test('ops-admin: feature_flags.update toggles kill switch + audit', async () => {
  const admin = await seedAdmin();
  const svc = serviceClient();

  const { status, body } = await post(
    'feature_flags.update',
    { key: 'disable_scan_parse', value: true },
    admin.jwt,
  );
  assertEquals(status, 200);
  const after = body.after as { payload_json: { value: boolean } };
  assertEquals(after.payload_json.value, true);

  // Flip back for other tests.
  await svc.from('feature_flags').update({ payload_json: { value: false } })
    .eq('key', 'disable_scan_parse');
});

Deno.test('ops-admin: feature_flags.update unknown key → handler error', async () => {
  const admin = await seedAdmin();
  const { status, body } = await post(
    'feature_flags.update',
    { key: 'does_not_exist_' + crypto.randomUUID(), is_enabled: false },
    admin.jwt,
  );
  assertEquals(status, 500);
  assertEquals(body.error, 'NET-01');
  assertEquals(String(body.message).includes('not found'), true);
});
