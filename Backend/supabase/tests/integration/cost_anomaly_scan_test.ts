// SCA-121 — integration coverage for stir_ops_cost_anomaly_scan after the
// session_id rewrite + runaway_session detector emit.
//
// Migration: 20260509144834_cost_anomaly_scan_session_id_rewrite.sql.
//
// Coverage:
//   1. voice_session_tokens_over_cap: existing detector still emits when
//      cumulative tokens cross 50K (regression guard — the rewrite
//      mustn't have lost behavior).
//   2. runaway_session: new detector emits for sessions with >10-min
//      span AND >20 turns; details_json includes duration_ms + turn_count
//      + session_id (per spec §13).
//   3. runaway_session does NOT emit for a session with 21 turns over
//      9 minutes (turn count fires, span doesn't).
//   4. runaway_session does NOT emit for a session with 11 minutes but
//      only 20 turns (span fires, turn count doesn't — strict greater-than).
//   5. Dedup: a second scan call within the 24h window doesn't insert a
//      duplicate runaway_session row for the same session.
//   6. Index-backed query smoke: rows whose session_id is NULL (non-voice
//      feature_key) are not picked up. Pre-rewrite filter
//      `request_id LIKE 'voice:%:%'` would have caught these incidentally;
//      the new shape relies on the partial index's WHERE clause.
//   7. Tokens + runaway co-trigger: a session that's both >50K tokens
//      AND >10min/>20turns emits BOTH anomaly rows (different
//      anomaly_types, different ops semantics).

import '../_helpers/env.ts';
import { assertEquals } from '@std/assert';
import { serviceClient } from '../_helpers/pg.ts';

interface SeedTurnSpec {
  sessionId: string;
  canonicalKey: string;
  turnIndex: number;
  inputTokens: number;
  outputTokens: number;
  /** Offset from "now" in seconds — negative = past, 0 = now. */
  ageSeconds: number;
}

/** Insert one ai_request_log row shaped like a voice turn. */
async function insertVoiceTurn(spec: SeedTurnSpec): Promise<void> {
  const svc = serviceClient();
  const createdAt = new Date(Date.now() + spec.ageSeconds * 1000).toISOString();
  const requestId = `voice:${spec.sessionId}:${spec.turnIndex}`;
  const { error } = await svc.from('ai_request_log').insert({
    request_id: requestId,
    canonical_user_key: spec.canonicalKey,
    feature_key: 'cook_mode_realtime',
    model: 'gemini-3.1-flash-live-preview',
    input_tokens: spec.inputTokens,
    output_tokens: spec.outputTokens,
    cost_usd: 0.001,
    latency_ms: 1200,
    thinking_level: 'minimal',
    prompt_version: '1.0.0',
    session_id: spec.sessionId,
    created_at: createdAt,
  });
  if (error) throw new Error(`insertVoiceTurn failed: ${error.message}`);
}

/** Seed an app_user the FK on ai_request_log can satisfy. */
async function seedUser(): Promise<string> {
  const svc = serviceClient();
  const canonicalKey = `ck:test:sca121:${crypto.randomUUID()}`;
  const { error } = await svc.from('app_users').insert({
    canonical_user_key: canonicalKey,
    current_install_id: crypto.randomUUID(),
    revenuecat_app_user_id: canonicalKey,
    source_type: 'cloudkit',
    status: 'active',
  });
  if (error) throw new Error(`seedUser failed: ${error.message}`);
  return canonicalKey;
}

async function cleanupUser(canonicalKey: string): Promise<void> {
  const svc = serviceClient();
  // ai_request_log doesn't FK-cascade off app_users, so delete its rows
  // explicitly (test-scoped key prefix keeps the filter narrow).
  await svc.from('ai_request_log').delete().eq('canonical_user_key', canonicalKey);
  await svc.from('app_users').delete().eq('canonical_user_key', canonicalKey);
}

/** Hash the canonical key the same way `stir_hash_user_key` does — used
 *  to filter the cost_anomalies rows we expect to see for a test user. */
async function expectedHash(canonicalKey: string): Promise<string> {
  const svc = serviceClient();
  const { data, error } = await svc.rpc('stir_hash_user_key', { p_key: canonicalKey });
  if (error) throw new Error(`stir_hash_user_key failed: ${error.message}`);
  return data as string;
}

async function clearAnomaliesForUser(canonicalKey: string): Promise<void> {
  const svc = serviceClient();
  const hash = await expectedHash(canonicalKey);
  await svc.from('cost_anomalies').delete().eq('canonical_user_key_hash', hash);
}

async function runScan(): Promise<number> {
  const svc = serviceClient();
  const { data, error } = await svc.rpc('stir_ops_cost_anomaly_scan');
  if (error) throw new Error(`stir_ops_cost_anomaly_scan failed: ${error.message}`);
  return data as number;
}

Deno.test('SCA-121 cost_anomaly_scan: voice_session_tokens_over_cap still fires (regression guard)', async () => {
  const canonicalKey = await seedUser();
  const sessionId = crypto.randomUUID();
  try {
    // Single turn with 60K tokens → trips the 50K threshold.
    await insertVoiceTurn({
      sessionId,
      canonicalKey,
      turnIndex: 1,
      inputTokens: 30000,
      outputTokens: 30000,
      ageSeconds: -60,
    });

    await runScan();

    const svc = serviceClient();
    const hash = await expectedHash(canonicalKey);
    const { data: rows } = await svc
      .from('cost_anomalies')
      .select('anomaly_type, severity, details_json')
      .eq('canonical_user_key_hash', hash)
      .eq('anomaly_type', 'voice_session_tokens_over_cap');
    assertEquals((rows ?? []).length, 1);
    assertEquals(rows![0]!.severity, 'critical');
    const details = rows![0]!.details_json as Record<string, unknown>;
    assertEquals(details.session_id, sessionId);
    assertEquals(details.total_tokens, 60000);
    assertEquals(details.turn_count, 1);
  } finally {
    await clearAnomaliesForUser(canonicalKey);
    await cleanupUser(canonicalKey);
  }
});

Deno.test('SCA-121 cost_anomaly_scan: runaway_session emits for >10-min span AND >20 turns', async () => {
  const canonicalKey = await seedUser();
  const sessionId = crypto.randomUUID();
  try {
    // 21 turns spanning 11 minutes — first turn at -660s, last at 0s.
    // 21 turns evenly spaced over 660s = 33s spacing. We use small
    // tokens (well below the 50K threshold) so this trips runaway
    // ONLY, not the tokens-over-cap branch.
    for (let i = 0; i < 21; i++) {
      const ageSeconds = -660 + Math.floor((i * 660) / 20);
      await insertVoiceTurn({
        sessionId,
        canonicalKey,
        turnIndex: i + 1,
        inputTokens: 100,
        outputTokens: 100,
        ageSeconds,
      });
    }

    await runScan();

    const svc = serviceClient();
    const hash = await expectedHash(canonicalKey);
    const { data: rows } = await svc
      .from('cost_anomalies')
      .select('anomaly_type, severity, details_json')
      .eq('canonical_user_key_hash', hash)
      .eq('anomaly_type', 'runaway_session');
    assertEquals((rows ?? []).length, 1);
    assertEquals(rows![0]!.severity, 'critical');
    const details = rows![0]!.details_json as Record<string, unknown>;
    assertEquals(details.session_id, sessionId);
    assertEquals(details.turn_count, 21);
    // duration_ms is float-seconds * 1000; should be ~660_000 ± a few s.
    const durationMs = details.duration_ms as number;
    if (typeof durationMs !== 'number' || durationMs < 600_000 || durationMs > 720_000) {
      throw new Error(`expected duration_ms ~660000; got ${durationMs}`);
    }
  } finally {
    await clearAnomaliesForUser(canonicalKey);
    await cleanupUser(canonicalKey);
  }
});

Deno.test('SCA-121 cost_anomaly_scan: 21 turns over 9 minutes does NOT emit runaway (span gate)', async () => {
  const canonicalKey = await seedUser();
  const sessionId = crypto.randomUUID();
  try {
    // 21 turns spanning 9 minutes (540s) — turn count exceeds threshold
    // but span does not. Strict greater-than on (last - started) > 10 min
    // keeps this off the runaway path.
    for (let i = 0; i < 21; i++) {
      const ageSeconds = -540 + Math.floor((i * 540) / 20);
      await insertVoiceTurn({
        sessionId,
        canonicalKey,
        turnIndex: i + 1,
        inputTokens: 100,
        outputTokens: 100,
        ageSeconds,
      });
    }

    await runScan();

    const svc = serviceClient();
    const hash = await expectedHash(canonicalKey);
    const { data: rows } = await svc
      .from('cost_anomalies')
      .select('anomaly_type')
      .eq('canonical_user_key_hash', hash)
      .eq('anomaly_type', 'runaway_session');
    assertEquals((rows ?? []).length, 0);
  } finally {
    await clearAnomaliesForUser(canonicalKey);
    await cleanupUser(canonicalKey);
  }
});

Deno.test('SCA-121 cost_anomaly_scan: 20 turns over 11 minutes does NOT emit runaway (turn gate)', async () => {
  const canonicalKey = await seedUser();
  const sessionId = crypto.randomUUID();
  try {
    // 20 turns spanning 11 minutes (660s) — span exceeds threshold but
    // turn count does not. Strict greater-than on turn_count > 20 keeps
    // this off the runaway path.
    for (let i = 0; i < 20; i++) {
      const ageSeconds = -660 + Math.floor((i * 660) / 19);
      await insertVoiceTurn({
        sessionId,
        canonicalKey,
        turnIndex: i + 1,
        inputTokens: 100,
        outputTokens: 100,
        ageSeconds,
      });
    }

    await runScan();

    const svc = serviceClient();
    const hash = await expectedHash(canonicalKey);
    const { data: rows } = await svc
      .from('cost_anomalies')
      .select('anomaly_type')
      .eq('canonical_user_key_hash', hash)
      .eq('anomaly_type', 'runaway_session');
    assertEquals((rows ?? []).length, 0);
  } finally {
    await clearAnomaliesForUser(canonicalKey);
    await cleanupUser(canonicalKey);
  }
});

Deno.test('SCA-121 cost_anomaly_scan: dedup — second scan within 24h does NOT insert duplicate runaway row', async () => {
  const canonicalKey = await seedUser();
  const sessionId = crypto.randomUUID();
  try {
    for (let i = 0; i < 21; i++) {
      const ageSeconds = -660 + Math.floor((i * 660) / 20);
      await insertVoiceTurn({
        sessionId,
        canonicalKey,
        turnIndex: i + 1,
        inputTokens: 100,
        outputTokens: 100,
        ageSeconds,
      });
    }

    await runScan();
    await runScan();

    const svc = serviceClient();
    const hash = await expectedHash(canonicalKey);
    const { data: rows } = await svc
      .from('cost_anomalies')
      .select('id')
      .eq('canonical_user_key_hash', hash)
      .eq('anomaly_type', 'runaway_session');
    assertEquals((rows ?? []).length, 1);
  } finally {
    await clearAnomaliesForUser(canonicalKey);
    await cleanupUser(canonicalKey);
  }
});

Deno.test('SCA-121 cost_anomaly_scan: NULL session_id (non-voice rows) are skipped', async () => {
  // The new query filters on session_id IS NOT NULL. Any
  // ai_request_log row inserted with session_id=NULL (e.g., a
  // non-voice feature_key wrongly tagged 'cook_mode_realtime', or an
  // older row that never got backfilled) MUST NOT be picked up.
  const canonicalKey = await seedUser();
  try {
    const svc = serviceClient();
    // Insert 21 cook_mode_realtime rows with NULL session_id; they
    // must NOT trigger any anomaly even though they'd otherwise look
    // like runaway shape.
    for (let i = 0; i < 21; i++) {
      const { error } = await svc.from('ai_request_log').insert({
        request_id: `legacy:${canonicalKey}:${i}`,
        canonical_user_key: canonicalKey,
        feature_key: 'cook_mode_realtime',
        model: 'gemini-3.1-flash-live-preview',
        input_tokens: 100,
        output_tokens: 100,
        cost_usd: 0.001,
        latency_ms: 1200,
        thinking_level: 'minimal',
        prompt_version: '1.0.0',
        session_id: null,
        created_at: new Date(Date.now() + (-660 + Math.floor((i * 660) / 20)) * 1000).toISOString(),
      });
      if (error) throw new Error(`insert failed: ${error.message}`);
    }

    await runScan();

    const hash = await expectedHash(canonicalKey);
    const { data: rows } = await svc
      .from('cost_anomalies')
      .select('anomaly_type')
      .eq('canonical_user_key_hash', hash)
      .in('anomaly_type', ['runaway_session', 'voice_session_tokens_over_cap']);
    assertEquals((rows ?? []).length, 0);
  } finally {
    await clearAnomaliesForUser(canonicalKey);
    await cleanupUser(canonicalKey);
  }
});

Deno.test('SCA-121 cost_anomaly_scan: session that crosses BOTH thresholds emits BOTH anomaly rows', async () => {
  const canonicalKey = await seedUser();
  const sessionId = crypto.randomUUID();
  try {
    // 21 turns spanning 11 minutes (runaway threshold) AND each turn
    // is 3K tokens so cumulative is 63K (over 50K tokens-over-cap
    // threshold). Two distinct anomaly_types should land — different
    // ops semantics, different routes through resolution flow.
    for (let i = 0; i < 21; i++) {
      const ageSeconds = -660 + Math.floor((i * 660) / 20);
      await insertVoiceTurn({
        sessionId,
        canonicalKey,
        turnIndex: i + 1,
        inputTokens: 1500,
        outputTokens: 1500,
        ageSeconds,
      });
    }

    await runScan();

    const svc = serviceClient();
    const hash = await expectedHash(canonicalKey);
    const { data: rows } = await svc
      .from('cost_anomalies')
      .select('anomaly_type')
      .eq('canonical_user_key_hash', hash);
    const types = (rows ?? []).map((r) => r.anomaly_type as string).sort();
    assertEquals(types, ['runaway_session', 'voice_session_tokens_over_cap']);
  } finally {
    await clearAnomaliesForUser(canonicalKey);
    await cleanupUser(canonicalKey);
  }
});
