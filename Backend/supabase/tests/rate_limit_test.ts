// rate_limit_test
//
// Direct-to-Postgres unit tests for stir_rate_limit_check(). No HTTP;
// exercises the RPC straight through the service-role client.
//
// Scoped bucket keys carry a 'test:' prefix so CI cleanup is trivial.

import { assertEquals } from '@std/assert';
import { serviceClient } from './_helpers/pg.ts';

interface CheckResult {
  allowed: boolean;
  current_count: number;
  reset_at: string;
  retry_after_seconds: number;
}

async function checkRateLimit(
  scope: string,
  bucket: string,
  windowSeconds: number,
  maxCount: number,
): Promise<CheckResult> {
  const { data, error } = await serviceClient().rpc('stir_rate_limit_check', {
    p_scope_key: scope,
    p_bucket_key: bucket,
    p_window_seconds: windowSeconds,
    p_max_count: maxCount,
  });
  if (error) throw error;
  const row = Array.isArray(data) ? data[0] : data;
  return row as CheckResult;
}

Deno.test('rate-limit: under cap allows + increments monotonically', async () => {
  const bucket = `test:${crypto.randomUUID()}`;
  const r1 = await checkRateLimit('test:scope', bucket, 60, 3);
  const r2 = await checkRateLimit('test:scope', bucket, 60, 3);
  const r3 = await checkRateLimit('test:scope', bucket, 60, 3);
  assertEquals(r1.allowed, true);
  assertEquals(r2.allowed, true);
  assertEquals(r3.allowed, true);
  assertEquals(r1.current_count, 1);
  assertEquals(r2.current_count, 2);
  assertEquals(r3.current_count, 3);
});

Deno.test('rate-limit: at cap blocks + populates retry_after_seconds', async () => {
  const bucket = `test:${crypto.randomUUID()}`;
  await checkRateLimit('test:scope', bucket, 60, 2);
  await checkRateLimit('test:scope', bucket, 60, 2);
  const blocked = await checkRateLimit('test:scope', bucket, 60, 2);
  assertEquals(blocked.allowed, false);
  assertEquals(blocked.current_count, 2);
  // Minute-bucketed window; retry window is at most 60s.
  if (blocked.retry_after_seconds < 1 || blocked.retry_after_seconds > 60) {
    throw new Error(`retry_after_seconds out of window: ${blocked.retry_after_seconds}`);
  }
});

Deno.test('rate-limit: independent buckets do not share counters', async () => {
  const a = `test:${crypto.randomUUID()}`;
  const b = `test:${crypto.randomUUID()}`;
  await checkRateLimit('test:scope', a, 60, 1);
  // a is at cap
  const aBlocked = await checkRateLimit('test:scope', a, 60, 1);
  assertEquals(aBlocked.allowed, false);
  // b is a fresh bucket
  const bFirst = await checkRateLimit('test:scope', b, 60, 1);
  assertEquals(bFirst.allowed, true);
});

Deno.test('rate-limit: independent scopes do not share counters', async () => {
  const bucket = `test:${crypto.randomUUID()}`;
  await checkRateLimit('test:scope-a', bucket, 60, 1);
  const scopeABlocked = await checkRateLimit('test:scope-a', bucket, 60, 1);
  assertEquals(scopeABlocked.allowed, false);
  const scopeBFresh = await checkRateLimit('test:scope-b', bucket, 60, 1);
  assertEquals(scopeBFresh.allowed, true);
});

Deno.test('rate-limit: reset_at populated on both allowed + blocked paths', async () => {
  const bucket = `test:${crypto.randomUUID()}`;
  const allowed = await checkRateLimit('test:scope', bucket, 60, 1);
  const blocked = await checkRateLimit('test:scope', bucket, 60, 1);
  // ISO timestamp string present.
  if (!Date.parse(allowed.reset_at)) throw new Error('allowed reset_at not a date');
  if (!Date.parse(blocked.reset_at)) throw new Error('blocked reset_at not a date');
});
