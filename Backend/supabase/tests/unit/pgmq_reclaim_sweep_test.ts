// SCA-125 — direct-DB unit tests for `stir_pgmq_reclaim_sweep()`.
//
// Migration: 20260509145809_pgmq_reclaim_sweep_proc.sql.
//
// These tests bypass the edge runtime entirely: they call the SQL proc
// via service-role PostgREST RPC and inspect notification_jobs row
// state directly. That's the whole point of the SCA-125 extraction —
// reclaim-sweep behavior is a logically-pure DB operation that
// previously lived in TS at `pgmq-dispatch/index.ts` and was only
// exercisable via HTTP `/functions/v1/pgmq-dispatch` POSTs.
//
// Coverage:
//   1. Part A: state='processing' AND attempt_count < MAX AND stale
//      updated_at → state='pending', error_message='reclaimed after
//      stuck processing window', updated_at advances.
//   2. Part B: state='processing' AND attempt_count >= MAX AND stale
//      updated_at → state='failed', error_message='reclaim_max_
//      attempts_reached', processed_at populated.
//   3. Fresh updated_at (within stale window) is left alone — neither
//      branch fires.
//   4. Non-processing rows are untouched (state='pending' / 'completed'
//      / 'failed' all skip the sweep).
//   5. Argument override: p_stale_minutes=1 reclaims rows older than 1
//      minute (vs the default 5).
//   6. Return shape: jsonb summary with reclaimed_count +
//      dead_lettered_count + cutoff + stale_minutes + max_attempts.
//   7. Argument validation: p_stale_minutes=0 falls back to default
//      (clamp guard so a programmer error can't flip ALL processing
//      rows mid-tick).

import '../_helpers/env.ts';
import { assertEquals } from '@std/assert';
import { serviceClient } from '../_helpers/pg.ts';

interface SeededFixture {
  canonicalKey: string;
  jobIds: string[];
}

function minutesAgoISO(n: number): string {
  return new Date(Date.now() - n * 60_000).toISOString();
}

async function seedUserAndJobs(
  rows: Array<
    {
      state: 'pending' | 'processing' | 'completed' | 'failed';
      attempt_count: number;
      updated_at_minutes_ago: number;
    }
  >,
): Promise<SeededFixture> {
  const svc = serviceClient();
  const canonicalKey = `ck:test:sca125:${crypto.randomUUID()}`;
  const { error: userErr } = await svc.from('app_users').insert({
    canonical_user_key: canonicalKey,
    current_install_id: crypto.randomUUID(),
    revenuecat_app_user_id: canonicalKey,
    source_type: 'cloudkit',
    status: 'active',
  });
  if (userErr) throw new Error(`seed app_users failed: ${userErr.message}`);

  const jobIds: string[] = [];
  for (const r of rows) {
    const { data, error } = await svc.from('notification_jobs').insert({
      canonical_user_key: canonicalKey,
      kind: 'push_send',
      payload_json: {
        template: 'reactivation',
        title: 't',
        body: 'b',
        apns_token: '0'.repeat(64),
        environment: 'sandbox',
      },
      state: r.state,
      attempt_count: r.attempt_count,
      updated_at: minutesAgoISO(r.updated_at_minutes_ago),
    }).select('id').single();
    if (error || !data) throw new Error(`seed notification_jobs failed: ${error?.message}`);
    jobIds.push(data.id);
  }
  return { canonicalKey, jobIds };
}

async function cleanupFixture(canonicalKey: string): Promise<void> {
  const svc = serviceClient();
  await svc.from('app_users').delete().eq('canonical_user_key', canonicalKey);
}

async function runSweep(args?: {
  p_stale_minutes?: number;
  p_max_attempts?: number;
}): Promise<{
  reclaimed_count: number;
  dead_lettered_count: number;
  cutoff: string;
  stale_minutes: number;
  max_attempts: number;
}> {
  const svc = serviceClient();
  const { data, error } = await svc.rpc('stir_pgmq_reclaim_sweep', args ?? {});
  if (error) throw new Error(`stir_pgmq_reclaim_sweep failed: ${error.message}`);
  return data as {
    reclaimed_count: number;
    dead_lettered_count: number;
    cutoff: string;
    stale_minutes: number;
    max_attempts: number;
  };
}

Deno.test('SCA-125 stir_pgmq_reclaim_sweep: Part A reclaims state=processing + attempt_count<MAX → pending', async () => {
  const fx = await seedUserAndJobs([
    { state: 'processing', attempt_count: 1, updated_at_minutes_ago: 6 },
  ]);
  try {
    const result = await runSweep();
    assertEquals(result.reclaimed_count, 1);
    assertEquals(result.dead_lettered_count, 0);

    const svc = serviceClient();
    const { data } = await svc
      .from('notification_jobs')
      .select('state, error_message, processed_at')
      .eq('id', fx.jobIds[0]!)
      .single();
    assertEquals(data?.state, 'pending');
    assertEquals(data?.error_message, 'reclaimed after stuck processing window');
    // Part A does NOT set processed_at (the row will be re-claimed).
    assertEquals(data?.processed_at, null);
  } finally {
    await cleanupFixture(fx.canonicalKey);
  }
});

Deno.test('SCA-125 stir_pgmq_reclaim_sweep: Part B dead-letters state=processing + attempt_count>=MAX → failed', async () => {
  const fx = await seedUserAndJobs([
    { state: 'processing', attempt_count: 3, updated_at_minutes_ago: 6 },
  ]);
  try {
    const result = await runSweep();
    assertEquals(result.reclaimed_count, 0);
    assertEquals(result.dead_lettered_count, 1);

    const svc = serviceClient();
    const { data } = await svc
      .from('notification_jobs')
      .select('state, error_message, processed_at')
      .eq('id', fx.jobIds[0]!)
      .single();
    assertEquals(data?.state, 'failed');
    assertEquals(data?.error_message, 'reclaim_max_attempts_reached');
    // Part B sets processed_at so terminal-state queries see the row
    // as resolved at sweep time.
    if (!data?.processed_at) {
      throw new Error('Part B must set processed_at on dead-letter');
    }
  } finally {
    await cleanupFixture(fx.canonicalKey);
  }
});

Deno.test('SCA-125 stir_pgmq_reclaim_sweep: rows within stale window are NOT touched', async () => {
  // updated_at = 2 minutes ago, stale_minutes default = 5 → row is fresh
  // and the sweep MUST leave it alone. This is the safety guard that
  // prevents the sweep from killing in-flight workers.
  const fx = await seedUserAndJobs([
    { state: 'processing', attempt_count: 1, updated_at_minutes_ago: 2 },
  ]);
  try {
    const result = await runSweep();
    assertEquals(result.reclaimed_count, 0);
    assertEquals(result.dead_lettered_count, 0);

    const svc = serviceClient();
    const { data } = await svc
      .from('notification_jobs')
      .select('state')
      .eq('id', fx.jobIds[0]!)
      .single();
    assertEquals(data?.state, 'processing');
  } finally {
    await cleanupFixture(fx.canonicalKey);
  }
});

Deno.test('SCA-125 stir_pgmq_reclaim_sweep: non-processing rows are untouched', async () => {
  // Pending / completed / failed rows are out of scope for the sweep
  // (which only targets state='processing'). All three states must
  // pass through unchanged even when their updated_at is stale.
  const fx = await seedUserAndJobs([
    { state: 'pending', attempt_count: 0, updated_at_minutes_ago: 6 },
    { state: 'completed', attempt_count: 1, updated_at_minutes_ago: 6 },
    { state: 'failed', attempt_count: 3, updated_at_minutes_ago: 6 },
  ]);
  try {
    const result = await runSweep();
    assertEquals(result.reclaimed_count, 0);
    assertEquals(result.dead_lettered_count, 0);

    const svc = serviceClient();
    const states: string[] = [];
    for (const id of fx.jobIds) {
      const { data } = await svc
        .from('notification_jobs')
        .select('state')
        .eq('id', id)
        .single();
      states.push(data?.state ?? '<missing>');
    }
    assertEquals(states, ['pending', 'completed', 'failed']);
  } finally {
    await cleanupFixture(fx.canonicalKey);
  }
});

Deno.test('SCA-125 stir_pgmq_reclaim_sweep: argument override — p_stale_minutes=1 reclaims rows >1min old', async () => {
  // Default stale_minutes is 5; override to 1 makes the sweep
  // aggressive (used by tests + ops "drain stuck queue now" runbook
  // calls).
  const fx = await seedUserAndJobs([
    { state: 'processing', attempt_count: 1, updated_at_minutes_ago: 2 },
  ]);
  try {
    const result = await runSweep({ p_stale_minutes: 1 });
    assertEquals(result.reclaimed_count, 1);
    assertEquals(result.stale_minutes, 1);
  } finally {
    await cleanupFixture(fx.canonicalKey);
  }
});

Deno.test('SCA-125 stir_pgmq_reclaim_sweep: return shape carries cutoff + stale_minutes + max_attempts', async () => {
  const fx = await seedUserAndJobs([]);
  try {
    const result = await runSweep({ p_stale_minutes: 7, p_max_attempts: 5 });
    assertEquals(result.reclaimed_count, 0);
    assertEquals(result.dead_lettered_count, 0);
    assertEquals(result.stale_minutes, 7);
    assertEquals(result.max_attempts, 5);
    if (typeof result.cutoff !== 'string' || !result.cutoff.startsWith('20')) {
      throw new Error(`expected cutoff ISO timestamp; got ${result.cutoff}`);
    }
  } finally {
    await cleanupFixture(fx.canonicalKey);
  }
});

Deno.test('SCA-125 stir_pgmq_reclaim_sweep: p_stale_minutes=0 falls back to default (clamp guard)', async () => {
  // Programmer-error guard: if a caller passes 0 or negative the proc
  // clamps back to the 5-minute default rather than letting the sweep
  // flip ALL state=processing rows mid-tick (which would be
  // catastrophic — every in-flight worker would race the reclaim).
  const fx = await seedUserAndJobs([
    { state: 'processing', attempt_count: 1, updated_at_minutes_ago: 2 },
  ]);
  try {
    const result = await runSweep({ p_stale_minutes: 0 });
    // 2-minute-old row should NOT be reclaimed because clamp pushes
    // stale_minutes back to 5.
    assertEquals(result.reclaimed_count, 0);
    assertEquals(result.stale_minutes, 5);
  } finally {
    await cleanupFixture(fx.canonicalKey);
  }
});
