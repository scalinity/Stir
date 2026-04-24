// Step 8 Phase 1.5 — ops_admin RPCs.
//
// Exercises each stir_ops_* function via service-role client (matches how
// ops-admin Edge Function will call them in Phase 2). Also verifies the
// double-gate: iOS session JWTs and authenticated-not-admin JWTs are
// rejected.

import './_helpers/env.ts';
import { assertEquals, assertNotEquals, assertRejects } from '@std/assert';
import { hashCanonicalKey } from '../functions/_shared/hashing.ts';
import { clearRateLimitBuckets, serviceClient, userClient } from './_helpers/pg.ts';
import { seedAdmin, seedAuthOnlyUser } from './_helpers/admin_factory.ts';
import { quickBootstrap, testInstallId } from './_helpers/factory.ts';

await clearRateLimitBuckets();

// ---------------------------------------------------------------------------
// stir_hash_user_key — parity with hashCanonicalKey in TypeScript.
// ---------------------------------------------------------------------------

Deno.test('stir_hash_user_key: SHA-256 truncated to 16 hex matches TS hashCanonicalKey', async () => {
  const svc = serviceClient();
  const samples = [
    'install:abc-123',
    'ck:_deadbeef',
    'install:' + crypto.randomUUID(),
    'ck:_' + crypto.randomUUID().replaceAll('-', ''),
  ];
  for (const key of samples) {
    const tsHash = await hashCanonicalKey(key);
    const { data, error } = await svc.rpc('stir_hash_user_key', { p_key: key });
    assertEquals(error, null);
    assertEquals(data, tsHash, `sql and ts hashes must match for key=${key}`);
  }
});

// ---------------------------------------------------------------------------
// stir_ops_list_users
// ---------------------------------------------------------------------------

Deno.test('stir_ops_list_users: service-role call returns paginated users', async () => {
  const svc = serviceClient();
  // Seed a few users.
  const sessions = await Promise.all([
    quickBootstrap(),
    quickBootstrap(),
    quickBootstrap(),
  ]);

  const { data, error } = await svc.rpc('stir_ops_list_users', { p_limit: 500 });
  assertEquals(error, null);
  const users = (data as { users: Array<{ canonical_user_key: string }> }).users;
  const total = (data as { total_count: number }).total_count;

  // Expect at least our three seeded users.
  const keys = new Set(users.map((u) => u.canonical_user_key));
  for (const s of sessions) {
    assertEquals(keys.has(s.canonical_user_key), true, `user ${s.canonical_user_key} should appear`);
  }
  assertEquals(total >= 3, true);
});

Deno.test('stir_ops_list_users: tier filter narrows results', async () => {
  const svc = serviceClient();
  // Freshly bootstrapped users default to 'free' tier.
  await quickBootstrap();

  const { data, error } = await svc.rpc('stir_ops_list_users', {
    p_tier: 'pro',
    p_limit: 500,
  });
  assertEquals(error, null);
  const users = (data as { users: Array<{ tier: string }> }).users;
  for (const u of users) {
    assertEquals(u.tier, 'pro');
  }
});

Deno.test('stir_ops_list_users: search matches canonical_user_key substring', async () => {
  const svc = serviceClient();
  const unique = crypto.randomUUID();
  const session = await quickBootstrap({ installation_id: unique });

  const { data, error } = await svc.rpc('stir_ops_list_users', {
    p_search: unique,
    p_limit: 10,
  });
  assertEquals(error, null);
  const users = (data as { users: Array<{ canonical_user_key: string }> }).users;
  assertEquals(users.length >= 1, true);
  const keys = new Set(users.map((u) => u.canonical_user_key));
  assertEquals(keys.has(session.canonical_user_key), true);
});

Deno.test('stir_ops_list_users: authenticated non-admin is rejected', async () => {
  const user = await seedAuthOnlyUser();
  const client = userClient(user.jwt);
  const { error } = await client.rpc('stir_ops_list_users', { p_limit: 1 });
  assertNotEquals(error, null);
  // Two layers of defense that can reject this call:
  //   - PostgREST EXECUTE grant revoked for authenticated → "permission denied"
  //   - Or (if grant were added) function-body is_admin() OR service_role → "not admin"
  // Either is fine; both prove the non-admin path is closed.
  const msg = String(error!.message).toLowerCase();
  assertEquals(
    msg.includes('permission denied') || msg.includes('not admin'),
    true,
    `expected permission-denied or not-admin, got: ${error!.message}`,
  );
});

Deno.test('stir_ops_list_users: iOS session JWT rejected', async () => {
  const session = await quickBootstrap();
  const client = userClient(session.session_jwt);
  const { error } = await client.rpc('stir_ops_list_users', { p_limit: 1 });
  assertNotEquals(error, null);
});

// ---------------------------------------------------------------------------
// stir_ops_user_detail
// ---------------------------------------------------------------------------

Deno.test('stir_ops_user_detail: returns aggregated user blob', async () => {
  const svc = serviceClient();
  const session = await quickBootstrap();

  // Seed an ai_request_log row so ai_recent isn't empty.
  await svc.from('ai_request_log').insert({
    request_id: `test-${crypto.randomUUID()}`,
    canonical_user_key: session.canonical_user_key,
    feature_key: 'dinner_solve',
    model: 'gemini-3-flash-preview',
    input_tokens: 100,
    output_tokens: 50,
    cost_usd: 0.002,
    latency_ms: 400,
  });

  const { data, error } = await svc.rpc('stir_ops_user_detail', {
    p_canonical_user_key: session.canonical_user_key,
  });
  assertEquals(error, null);

  const detail = data as {
    user: { canonical_user_key: string };
    entitlement: { tier: string } | null;
    quotas: Array<{ feature_key: string }>;
    ai_recent: Array<{ feature_key: string }>;
    webhooks: unknown[];
    flagged_open: unknown[];
  };
  assertEquals(detail.user.canonical_user_key, session.canonical_user_key);
  // Bootstrap creates 3 usage_counters rows (dinner_solve / voice_cook_session / recipe_import).
  assertEquals(detail.quotas.length, 3);
  assertEquals(detail.ai_recent.length, 1);
  assertEquals(detail.ai_recent[0]!.feature_key, 'dinner_solve');
});

// ---------------------------------------------------------------------------
// stir_ops_reset_quota
// ---------------------------------------------------------------------------

Deno.test('stir_ops_reset_quota: zeros used_count + preserves cap_count', async () => {
  const svc = serviceClient();
  const session = await quickBootstrap();

  // Bump used_count to 3 via direct service-role update.
  await svc
    .from('usage_counters')
    .update({ used_count: 3 })
    .eq('canonical_user_key', session.canonical_user_key)
    .eq('feature_key', 'dinner_solve');

  const { data, error } = await svc.rpc('stir_ops_reset_quota', {
    p_canonical_user_key: session.canonical_user_key,
    p_feature_key: 'dinner_solve',
  });
  assertEquals(error, null);
  const result = data as { ok: boolean; before: { used_count: number; cap_count: number }; after: { used_count: number; cap_count: number } };
  assertEquals(result.ok, true);
  assertEquals(result.before.used_count, 3);
  assertEquals(result.after.used_count, 0);
  assertEquals(result.before.cap_count, result.after.cap_count, 'cap must be preserved');
});

Deno.test('stir_ops_reset_quota: no current row returns noop=true', async () => {
  const svc = serviceClient();
  // Create an isolated user with NO usage_counters rows by skipping bootstrap.
  // Reset on a non-existent user+feature returns noop.
  const { data, error } = await svc.rpc('stir_ops_reset_quota', {
    p_canonical_user_key: 'install:does-not-exist-' + crypto.randomUUID(),
    p_feature_key: 'dinner_solve',
  });
  assertEquals(error, null);
  const r = data as { noop: boolean };
  assertEquals(r.noop, true);
});

// ---------------------------------------------------------------------------
// stir_ops_set_user_status
// ---------------------------------------------------------------------------

Deno.test('stir_ops_set_user_status: active → banned transition works', async () => {
  const svc = serviceClient();
  const session = await quickBootstrap();

  const { data, error } = await svc.rpc('stir_ops_set_user_status', {
    p_canonical_user_key: session.canonical_user_key,
    p_status: 'banned',
  });
  assertEquals(error, null);
  const r = data as { before: { status: string }; after: { status: string } };
  assertEquals(r.before.status, 'active');
  assertEquals(r.after.status, 'banned');

  // Transition back to active.
  const { error: errBack } = await svc.rpc('stir_ops_set_user_status', {
    p_canonical_user_key: session.canonical_user_key,
    p_status: 'active',
  });
  assertEquals(errBack, null);
});

Deno.test('stir_ops_set_user_status: refuses merged', async () => {
  const svc = serviceClient();
  const session = await quickBootstrap();

  const { error } = await svc.rpc('stir_ops_set_user_status', {
    p_canonical_user_key: session.canonical_user_key,
    p_status: 'merged',
  });
  assertNotEquals(error, null);
  assertEquals(String(error!.message).toLowerCase().includes('merged'), true);
});

Deno.test('stir_ops_set_user_status: not-found user raises', async () => {
  const svc = serviceClient();
  const { error } = await svc.rpc('stir_ops_set_user_status', {
    p_canonical_user_key: 'install:nope-' + crypto.randomUUID(),
    p_status: 'banned',
  });
  assertNotEquals(error, null);
});

// ---------------------------------------------------------------------------
// stir_ops_force_reauth
// ---------------------------------------------------------------------------

Deno.test('stir_ops_force_reauth: sets reauth_required_at + before/after snapshot', async () => {
  const svc = serviceClient();
  const session = await quickBootstrap();

  const { data, error } = await svc.rpc('stir_ops_force_reauth', {
    p_canonical_user_key: session.canonical_user_key,
  });
  assertEquals(error, null);
  const r = data as { before: { reauth_required_at: string | null }; after: { reauth_required_at: string } };
  assertEquals(r.before.reauth_required_at, null);
  assertNotEquals(r.after.reauth_required_at, null);

  // Verify DB state.
  const { data: row } = await svc
    .from('app_users')
    .select('reauth_required_at')
    .eq('canonical_user_key', session.canonical_user_key)
    .single();
  assertNotEquals(row?.reauth_required_at, null);
});

// ---------------------------------------------------------------------------
// stir_ops_list_voice_sessions
// ---------------------------------------------------------------------------

Deno.test('stir_ops_list_voice_sessions: aggregates by trace_id + sorts by token use', async () => {
  const svc = serviceClient();
  const session = await quickBootstrap();

  // Voice-turn-usage writes request_id = 'voice:<session_id>:<turn_index>'.
  // stir_ops_list_voice_sessions extracts session_id via split_part.
  const longSession = crypto.randomUUID();
  const shortSession = crypto.randomUUID();

  // Seed 5 turns under longSession (high cumulative tokens).
  for (let i = 0; i < 5; i++) {
    await svc.from('ai_request_log').insert({
      request_id: `voice:${longSession}:${i}`,
      canonical_user_key: session.canonical_user_key,
      feature_key: 'cook_mode_realtime',
      model: 'gemini-3.1-flash-live-preview',
      input_tokens: 2000,
      output_tokens: 500,
      cost_usd: 0.01,
      latency_ms: 600,
    });
  }
  // Seed 2 turns under shortSession (low cumulative tokens).
  for (let i = 0; i < 2; i++) {
    await svc.from('ai_request_log').insert({
      request_id: `voice:${shortSession}:${i}`,
      canonical_user_key: session.canonical_user_key,
      feature_key: 'cook_mode_realtime',
      model: 'gemini-3.1-flash-live-preview',
      input_tokens: 500,
      output_tokens: 100,
      cost_usd: 0.002,
      latency_ms: 600,
    });
  }

  // 500 is the RPC's max p_limit; avoids shortSession (1200 total tokens)
  // getting crowded out by higher-token sessions from earlier tests in the
  // shared DB.
  const { data, error } = await svc.rpc('stir_ops_list_voice_sessions', {
    p_limit: 500,
    p_min_tokens: 0,
  });
  assertEquals(error, null);
  const voiceSessions = (data as { sessions: Array<{ session_id: string; turn_count: number; cumulative_prompt_tokens: number }> }).sessions;

  const bySession = new Map(voiceSessions.map((s) => [s.session_id, s]));
  assertEquals(bySession.get(longSession)?.turn_count, 5);
  assertEquals(bySession.get(longSession)?.cumulative_prompt_tokens, 10000);
  assertEquals(bySession.get(shortSession)?.turn_count, 2);

  // The long session must appear BEFORE the short one (sort by tokens DESC).
  const order = voiceSessions.map((s) => s.session_id);
  const longIdx = order.indexOf(longSession);
  const shortIdx = order.indexOf(shortSession);
  assertEquals(longIdx < shortIdx, true);
});

Deno.test('stir_ops_list_voice_sessions: p_min_tokens filter excludes small sessions', async () => {
  const svc = serviceClient();
  const session = await quickBootstrap();

  const bigSession = crypto.randomUUID();
  const smallSession = crypto.randomUUID();
  await svc.from('ai_request_log').insert({
    request_id: `voice:${bigSession}:0`,
    canonical_user_key: session.canonical_user_key,
    feature_key: 'cook_mode_realtime',
    model: 'gemini-3.1-flash-live-preview',
    input_tokens: 50000,
    output_tokens: 10000,
    cost_usd: 0.5,
    latency_ms: 600,
  });
  await svc.from('ai_request_log').insert({
    request_id: `voice:${smallSession}:0`,
    canonical_user_key: session.canonical_user_key,
    feature_key: 'cook_mode_realtime',
    model: 'gemini-3.1-flash-live-preview',
    input_tokens: 100,
    output_tokens: 20,
    cost_usd: 0.001,
    latency_ms: 600,
  });

  const { data, error } = await svc.rpc('stir_ops_list_voice_sessions', {
    p_min_tokens: 50000,
    p_limit: 50,
  });
  assertEquals(error, null);
  const voiceSessions = (data as { sessions: Array<{ session_id: string }> }).sessions;
  const sessionIds = new Set(voiceSessions.map((s) => s.session_id));
  assertEquals(sessionIds.has(bigSession), true);
  assertEquals(sessionIds.has(smallSession), false);
});

// ---------------------------------------------------------------------------
// stir_ops_cost_anomaly_scan
// ---------------------------------------------------------------------------

async function seedPremiumUser(): Promise<{ canonical_user_key: string }> {
  const svc = serviceClient();
  const session = await quickBootstrap();
  // Promote to premium by updating entitlement_snapshots (no webhook flow).
  await svc
    .from('entitlement_snapshots')
    .update({ tier: 'premium', billing_state: 'active' })
    .eq('canonical_user_key', session.canonical_user_key);
  return session;
}

Deno.test('stir_ops_cost_anomaly_scan: detects Premium daily_spend_2x threshold', async () => {
  const svc = serviceClient();
  const user = await seedPremiumUser();
  const userHash = await hashCanonicalKey(user.canonical_user_key);

  // Spend $3.50 over the last hour (exceeds Premium $3 threshold).
  for (let i = 0; i < 5; i++) {
    await svc.from('ai_request_log').insert({
      request_id: `req-${crypto.randomUUID()}`,
      canonical_user_key: user.canonical_user_key,
      feature_key: 'dinner_solve',
      model: 'gemini-3-flash-preview',
      input_tokens: 10000,
      output_tokens: 2000,
      cost_usd: 0.70,
      latency_ms: 500,
    });
  }

  const { data, error } = await svc.rpc('stir_ops_cost_anomaly_scan');
  assertEquals(error, null);
  assertEquals((data as number) >= 1, true, 'scan should insert >=1 anomaly');

  const { data: anomalies } = await svc
    .from('cost_anomalies')
    .select('anomaly_type, severity')
    .eq('canonical_user_key_hash', userHash);
  assertEquals((anomalies ?? []).length >= 1, true);
  const types = new Set((anomalies ?? []).map((a) => a.anomaly_type));
  assertEquals(types.has('daily_spend_2x'), true);
});

Deno.test('stir_ops_cost_anomaly_scan: dedups within 24h window', async () => {
  const svc = serviceClient();
  const user = await seedPremiumUser();
  const userHash = await hashCanonicalKey(user.canonical_user_key);

  await svc.from('ai_request_log').insert({
    request_id: `req-${crypto.randomUUID()}`,
    canonical_user_key: user.canonical_user_key,
    feature_key: 'dinner_solve',
    model: 'gemini-3-flash-preview',
    input_tokens: 50000,
    output_tokens: 5000,
    cost_usd: 3.50,
    latency_ms: 500,
  });

  await svc.rpc('stir_ops_cost_anomaly_scan');
  const { count: count1 } = await svc
    .from('cost_anomalies')
    .select('id', { count: 'exact', head: true })
    .eq('canonical_user_key_hash', userHash)
    .eq('anomaly_type', 'daily_spend_2x');

  // Re-run the scan.
  await svc.rpc('stir_ops_cost_anomaly_scan');
  const { count: count2 } = await svc
    .from('cost_anomalies')
    .select('id', { count: 'exact', head: true })
    .eq('canonical_user_key_hash', userHash)
    .eq('anomaly_type', 'daily_spend_2x');

  assertEquals(count1, count2, 'dedup must prevent a second row within 24h');
});

Deno.test('stir_ops_cost_anomaly_scan: detects voice_session_tokens_over_cap', async () => {
  const svc = serviceClient();
  const session = await quickBootstrap();
  const sessionId = crypto.randomUUID();

  // Seed turns summing to > 50K tokens under one session_id.
  for (let i = 0; i < 10; i++) {
    await svc.from('ai_request_log').insert({
      request_id: `voice:${sessionId}:${i}`,
      canonical_user_key: session.canonical_user_key,
      feature_key: 'cook_mode_realtime',
      model: 'gemini-3.1-flash-live-preview',
      input_tokens: 5000,
      output_tokens: 1000,
      cost_usd: 0.03,
      latency_ms: 600,
    });
  }

  const { error } = await svc.rpc('stir_ops_cost_anomaly_scan');
  assertEquals(error, null);

  const userHash = await hashCanonicalKey(session.canonical_user_key);
  const { data } = await svc
    .from('cost_anomalies')
    .select('anomaly_type, details_json, severity')
    .eq('canonical_user_key_hash', userHash);
  const runaway = (data ?? []).find((r) => r.anomaly_type === 'voice_session_tokens_over_cap');
  assertNotEquals(runaway, undefined, 'voice runaway anomaly should be detected');
  assertEquals(runaway!.severity, 'critical');
  assertEquals((runaway!.details_json as { session_id: string }).session_id, sessionId);
});

// ---------------------------------------------------------------------------
// stir_ops_reactivation_enqueue
// ---------------------------------------------------------------------------

Deno.test('stir_ops_reactivation_enqueue: matches inactive user with push token + opt-in', async () => {
  const svc = serviceClient();
  const session = await quickBootstrap();

  // Move last_seen_at to 15 days ago.
  await svc
    .from('app_users')
    .update({ last_seen_at: new Date(Date.now() - 15 * 86400_000).toISOString() })
    .eq('canonical_user_key', session.canonical_user_key);

  // Write a push_token + reactivation=true opt-in onto the install row.
  await svc
    .from('device_installations')
    .update({
      push_token: 'fake-apns-token-' + crypto.randomUUID(),
      apns_environment: 'sandbox',
      notifications_enabled: true,
      notification_prefs_json: { reactivation: true },
    })
    .eq('canonical_user_key', session.canonical_user_key);

  const { data, error } = await svc.rpc('stir_ops_reactivation_enqueue');
  assertEquals(error, null);
  assertEquals((data as number) >= 1, true, 'should enqueue at least 1 reactivation push job');

  // Verify notification_jobs row exists.
  const { data: jobs } = await svc
    .from('notification_jobs')
    .select('kind, payload_json, state')
    .eq('canonical_user_key', session.canonical_user_key)
    .eq('kind', 'push_send');
  assertEquals((jobs ?? []).length, 1);
  assertEquals((jobs![0]!.payload_json as { template: string }).template, 'reactivation');
});

Deno.test('stir_ops_reactivation_enqueue: dedups within 30-day window', async () => {
  const svc = serviceClient();
  const session = await quickBootstrap();

  await svc
    .from('app_users')
    .update({ last_seen_at: new Date(Date.now() - 15 * 86400_000).toISOString() })
    .eq('canonical_user_key', session.canonical_user_key);

  await svc
    .from('device_installations')
    .update({
      push_token: 'fake-apns-' + crypto.randomUUID(),
      apns_environment: 'sandbox',
      notifications_enabled: true,
      notification_prefs_json: { reactivation: true },
    })
    .eq('canonical_user_key', session.canonical_user_key);

  // Pre-seed a recent reactivation job.
  await svc.from('notification_jobs').insert({
    canonical_user_key: session.canonical_user_key,
    kind: 'push_send',
    payload_json: { template: 'reactivation', foo: 'bar' },
  });

  const { data, error } = await svc.rpc('stir_ops_reactivation_enqueue');
  assertEquals(error, null);

  // The already-seeded job should have blocked a duplicate.
  const { data: jobs } = await svc
    .from('notification_jobs')
    .select('id')
    .eq('canonical_user_key', session.canonical_user_key)
    .eq('kind', 'push_send');
  assertEquals((jobs ?? []).length, 1, 'dedup should keep only the pre-seeded job');
});

Deno.test('stir_ops_reactivation_enqueue: skips opt-out users', async () => {
  const svc = serviceClient();
  const session = await quickBootstrap();

  await svc
    .from('app_users')
    .update({ last_seen_at: new Date(Date.now() - 15 * 86400_000).toISOString() })
    .eq('canonical_user_key', session.canonical_user_key);

  await svc
    .from('device_installations')
    .update({
      push_token: 'fake-apns-' + crypto.randomUUID(),
      apns_environment: 'sandbox',
      notifications_enabled: true,
      notification_prefs_json: { reactivation: false },
    })
    .eq('canonical_user_key', session.canonical_user_key);

  await svc.rpc('stir_ops_reactivation_enqueue');

  const { data: jobs } = await svc
    .from('notification_jobs')
    .select('id')
    .eq('canonical_user_key', session.canonical_user_key)
    .eq('kind', 'push_send');
  assertEquals((jobs ?? []).length, 0);
});

// ---------------------------------------------------------------------------
// Admin-JWT path via PostgREST (defense-in-depth: admin JWT should also pass)
// ---------------------------------------------------------------------------

Deno.test('stir_ops_list_users: admin JWT via PostgREST is rejected by grant (EXECUTE not granted to authenticated)', async () => {
  const admin = await seedAdmin();
  const client = userClient(admin.jwt);
  const { error } = await client.rpc('stir_ops_list_users', { p_limit: 1 });
  // Grants REVOKE FROM authenticated, so PostgREST returns permission denied
  // even though is_admin() WOULD return true. This is the intended posture:
  // admin flow goes through ops-admin Edge Function, not direct RPC.
  assertNotEquals(error, null);
  assertEquals(
    String(error!.message).toLowerCase().includes('permission') ||
      String(error!.code) === '42501',
    true,
  );
});
