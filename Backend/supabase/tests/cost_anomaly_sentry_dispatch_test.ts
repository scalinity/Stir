// Step 8 Phase 5 — Sentry alert dispatch for cost_anomalies.

import './_helpers/env.ts';
import { assertEquals, assertNotEquals } from '@std/assert';
import { serviceClient } from './_helpers/pg.ts';

Deno.test('dispatch: NULL SENTRY_DSN → returns 0, no rows marked dispatched', async () => {
  const svc = serviceClient();
  // Confirm no DSN set locally.
  await svc.from('app_settings').update({ value: null }).eq('key', 'SENTRY_DSN');

  const uniqHash = 'hash-dispatch-null-' + crypto.randomUUID().slice(0, 8);
  await svc.from('cost_anomalies').insert({
    canonical_user_key_hash: uniqHash,
    anomaly_type: 'daily_spend_2x',
    severity: 'warn',
    details_json: { spend_24h_usd: 3.50 },
  });

  const { data: sent } = await svc.rpc('stir_ops_cost_anomaly_alert_dispatch');
  // With null DSN, function returns 0 and leaves dispatched_at NULL.
  assertEquals(sent, 0);
  const { data: after } = await svc.from('cost_anomalies')
    .select('dispatched_at, confirmed_at').eq('canonical_user_key_hash', uniqHash).single();
  assertEquals(after?.dispatched_at, null);
  assertEquals(after?.confirmed_at, null);
});

Deno.test('dispatch: malformed DSN → RAISE WARNING, returns 0', async () => {
  const svc = serviceClient();
  await svc.from('app_settings').update({ value: 'not-a-valid-dsn' }).eq('key', 'SENTRY_DSN');

  const { data: sent } = await svc.rpc('stir_ops_cost_anomaly_alert_dispatch');
  assertEquals(sent, 0);

  // Restore null for other tests.
  await svc.from('app_settings').update({ value: null }).eq('key', 'SENTRY_DSN');
});

Deno.test('dispatch: valid DSN + unsent rows → enqueues via pg_net + stamps dispatched_at (review C15 two-phase)', async () => {
  const svc = serviceClient();
  try {
    await svc.from('app_settings').update({
      value: 'https://abcdef1234567890@o0000000.ingest.sentry.io/1234567',
    }).eq('key', 'SENTRY_DSN');

    const uniqHash = 'hash-dispatch-sent-' + crypto.randomUUID().slice(0, 8);
    await svc.from('cost_anomalies').insert({
      canonical_user_key_hash: uniqHash,
      anomaly_type: 'daily_spend_hard_cap',
      severity: 'critical',
      details_json: { spend_24h_usd: 12.5 },
    });

    const { data: sent } = await svc.rpc('stir_ops_cost_anomaly_alert_dispatch');
    assertEquals((sent as number) >= 1, true);

    // Post-fix: dispatched_at is set immediately with the pg_net handle;
    // confirmed_at is NULL until phase-2 (stir_ops_cost_anomaly_alert_confirm)
    // reads net._http_response.
    const { data: after } = await svc.from('cost_anomalies')
      .select('dispatched_at, sentry_request_id, confirmed_at')
      .eq('canonical_user_key_hash', uniqHash).single();
    assertNotEquals(after?.dispatched_at, null);
    assertNotEquals(after?.sentry_request_id, null);
    assertEquals(after?.confirmed_at, null);

    // Second dispatch should skip this row (dispatched_at IS NOT NULL).
    const { data: sentAgain } = await svc.rpc('stir_ops_cost_anomaly_alert_dispatch');
    void sentAgain;
    const { count: stillPending } = await svc.from('cost_anomalies')
      .select('id', { count: 'exact', head: true })
      .eq('canonical_user_key_hash', uniqHash)
      .is('dispatched_at', null);
    assertEquals(stillPending, 0);
  } finally {
    // W35 (CR3 #2): cleanup in finally so test failures don't leak DSN state.
    await svc.from('app_settings').update({ value: null }).eq('key', 'SENTRY_DSN');
  }
});
