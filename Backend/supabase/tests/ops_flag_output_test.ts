// Step 8 Phase 2 — ops-flag-output Edge Function tests.

import './_helpers/env.ts';
import { assertEquals, assertNotEquals } from '@std/assert';
import { clearRateLimitBuckets, serviceClient } from './_helpers/pg.ts';
import { quickBootstrap } from './_helpers/factory.ts';
import { hashCanonicalKey } from '../functions/_shared/hashing.ts';

await clearRateLimitBuckets();

const FUNCTIONS_URL = Deno.env.get('SUPABASE_URL')
  ? `${Deno.env.get('SUPABASE_URL')}/functions/v1`
  : 'http://127.0.0.1:54321/functions/v1';

async function postFlag(
  body: unknown,
  jwt: string | null,
): Promise<{ status: number; body: Record<string, unknown> }> {
  const headers: Record<string, string> = { 'content-type': 'application/json' };
  if (jwt) headers['Authorization'] = `Bearer ${jwt}`;
  const res = await fetch(`${FUNCTIONS_URL}/ops-flag-output`, {
    method: 'POST',
    headers,
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
  const parsed = await res.json();
  return { status: res.status, body: parsed };
}

Deno.test('ops-flag-output: missing Authorization → 401 AUTH-01 reason=missing', async () => {
  const { status, body } = await postFlag(
    { feature_key: 'substitution', request_id: 'x', flag_reason: 'bad' },
    null,
  );
  assertEquals(status, 401);
  assertEquals(body.error, 'AUTH-01');
  assertEquals(body.reason, 'missing');
});

Deno.test('ops-flag-output: malformed body → VAL-01', async () => {
  const session = await quickBootstrap();
  const { status, body } = await postFlag('not-json', session.session_jwt);
  assertEquals(status, 400);
  assertEquals(body.error, 'VAL-01');
});

Deno.test('ops-flag-output: missing required field → VAL-01 with field_errors', async () => {
  const session = await quickBootstrap();
  const { status, body } = await postFlag(
    { feature_key: 'substitution' }, // missing request_id + flag_reason
    session.session_jwt,
  );
  assertEquals(status, 400);
  assertEquals(body.error, 'VAL-01');
  const fieldErrors = body.field_errors as Array<{ field: string }>;
  const fields = new Set(fieldErrors.map((e) => e.field));
  assertEquals(fields.has('request_id'), true);
  assertEquals(fields.has('flag_reason'), true);
});

Deno.test('ops-flag-output: unknown feature_key → VAL-01', async () => {
  const session = await quickBootstrap();
  const { status, body } = await postFlag(
    { feature_key: 'fake_feature', request_id: 'x', flag_reason: 'bad' },
    session.session_jwt,
  );
  assertEquals(status, 400);
  assertEquals(body.error, 'VAL-01');
});

Deno.test('ops-flag-output: happy path inserts ops_flagged_outputs row', async () => {
  const session = await quickBootstrap();
  const svc = serviceClient();

  // Seed an ai_request_log + ai_response_cache so raw snapshot isn't empty.
  const reqId = crypto.randomUUID();
  await svc.from('ai_request_log').insert({
    request_id: reqId,
    canonical_user_key: session.canonical_user_key,
    feature_key: 'substitution',
    model: 'gemini-3-flash-preview',
    input_tokens: 500,
    output_tokens: 100,
    cost_usd: 0.003,
    latency_ms: 400,
  });
  await svc.from('ai_response_cache').insert({
    canonical_user_key: session.canonical_user_key,
    request_id: reqId,
    feature_key: 'substitution',
    status_code: 200,
    response_body: { substitution_text: 'peanut butter' },
  });

  const { status, body } = await postFlag(
    {
      feature_key: 'substitution',
      request_id: reqId,
      flag_reason: 'leaked peanut allergen',
      context_snapshot: { recipe_plan_id: crypto.randomUUID() },
    },
    session.session_jwt,
  );
  assertEquals(status, 200);
  assertEquals(body.ok, true);
  assertEquals(body.dedup, false);
  assertNotEquals(body.flagged_output_id, null);

  // Verify DB row shape.
  const userHash = await hashCanonicalKey(session.canonical_user_key);
  const { data: row } = await svc
    .from('ops_flagged_outputs')
    .select('feature_key, request_id, flagged_by, flag_reason, canonical_user_key_hash, raw_output_json, raw_input_json, context_snapshot_json')
    .eq('id', body.flagged_output_id as string)
    .single();
  assertEquals(row?.feature_key, 'substitution');
  assertEquals(row?.request_id, reqId);
  assertEquals(row?.flagged_by, 'user');
  assertEquals(row?.canonical_user_key_hash, userHash);
  assertEquals((row?.raw_output_json as { substitution_text: string }).substitution_text, 'peanut butter');
  assertNotEquals(row?.raw_input_json, null);
  assertNotEquals(row?.context_snapshot_json, null);
});

Deno.test('ops-flag-output: same user + request_id → dedup=true returns same id (forever)', async () => {
  const session = await quickBootstrap();
  const reqId = crypto.randomUUID();

  const first = await postFlag(
    { feature_key: 'dinner_solve', request_id: reqId, flag_reason: 'wrong dish' },
    session.session_jwt,
  );
  assertEquals(first.status, 200);
  assertEquals(first.body.dedup, false);
  const firstId = first.body.flagged_output_id;

  const second = await postFlag(
    { feature_key: 'dinner_solve', request_id: reqId, flag_reason: 'still wrong' },
    session.session_jwt,
  );
  assertEquals(second.status, 200);
  assertEquals(second.body.dedup, true);
  assertEquals(second.body.flagged_output_id, firstId);
});

Deno.test('ops-flag-output: different users flagging same request_id both land distinct rows', async () => {
  // Different canonical users → different hashes → dedup scoped per-user
  const sessionA = await quickBootstrap();
  const sessionB = await quickBootstrap();
  const reqId = crypto.randomUUID();

  const a = await postFlag(
    { feature_key: 'cook_turn', request_id: reqId, flag_reason: 'userA' },
    sessionA.session_jwt,
  );
  const b = await postFlag(
    { feature_key: 'cook_turn', request_id: reqId, flag_reason: 'userB' },
    sessionB.session_jwt,
  );
  assertEquals(a.status, 200);
  assertEquals(b.status, 200);
  assertNotEquals(a.body.flagged_output_id, b.body.flagged_output_id);
  assertEquals(a.body.dedup, false);
  assertEquals(b.body.dedup, false);
});

Deno.test('ops-flag-output: missing cache row → flag still created with raw_output_json=null', async () => {
  const session = await quickBootstrap();
  const svc = serviceClient();
  const reqId = crypto.randomUUID();
  // No ai_request_log / ai_response_cache seeded — orphan flag.

  const { status, body } = await postFlag(
    { feature_key: 'recipe_import', request_id: reqId, flag_reason: 'orphan' },
    session.session_jwt,
  );
  assertEquals(status, 200);
  assertEquals(body.ok, true);

  const { data: row } = await svc
    .from('ops_flagged_outputs')
    .select('raw_input_json, raw_output_json, flag_reason')
    .eq('id', body.flagged_output_id as string)
    .single();
  assertEquals(row?.raw_input_json, null);
  assertEquals(row?.raw_output_json, null);
  assertEquals(row?.flag_reason, 'orphan');
});

Deno.test('ops-flag-output: voice-format request_id (voice:<session>:<turn>) accepted', async () => {
  // Pre-migration 20260424000002 this failed SQLSTATE 22P02 because
  // ops_flagged_outputs.request_id was UUID. TEXT column now accepts the
  // voice shape from ai_request_log.
  const session = await quickBootstrap();
  const svc = serviceClient();
  const sessionId = crypto.randomUUID();
  const reqId = `voice:${sessionId}:7`;

  const { status, body } = await postFlag(
    { feature_key: 'cook_mode_realtime', request_id: reqId, flag_reason: 'voice path' },
    session.session_jwt,
  );
  assertEquals(status, 200);
  assertEquals(body.ok, true);
  assertEquals(body.dedup, false);

  const { data: row } = await svc
    .from('ops_flagged_outputs')
    .select('request_id, feature_key')
    .eq('id', body.flagged_output_id as string)
    .single();
  assertEquals(row?.request_id, reqId);
  assertEquals(row?.feature_key, 'cook_mode_realtime');
});

Deno.test('ops-flag-output: concurrent duplicate submissions → single row via UNIQUE + dedup response', async () => {
  // Concurrent submissions race at the pre-migration SELECT-then-INSERT
  // path. UNIQUE (canonical_user_key_hash, request_id) + ON CONFLICT
  // collapse them to one row; second submission reports dedup=true.
  const session = await quickBootstrap();
  const reqId = crypto.randomUUID();

  const [first, second] = await Promise.all([
    postFlag(
      { feature_key: 'dinner_solve', request_id: reqId, flag_reason: 'first submission' },
      session.session_jwt,
    ),
    postFlag(
      { feature_key: 'dinner_solve', request_id: reqId, flag_reason: 'second submission' },
      session.session_jwt,
    ),
  ]);

  assertEquals(first.status, 200);
  assertEquals(second.status, 200);
  // Exactly one must report dedup=false (the winner); the other dedup=true.
  const dedups = [first.body.dedup, second.body.dedup].sort();
  assertEquals(dedups, [false, true]);
  // Both must return the SAME flagged_output_id (only one row exists).
  assertEquals(first.body.flagged_output_id, second.body.flagged_output_id);
});
