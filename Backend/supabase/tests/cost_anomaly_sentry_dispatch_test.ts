// Step 8 Phase 5 — Sentry alert dispatch for cost_anomalies.

import './_helpers/env.ts';
import { assertEquals, assertNotEquals } from '@std/assert';
import { serviceClient } from './_helpers/pg.ts';

// SCA-362: per-test row cleanup. The dispatcher picks the 50 oldest
// `dispatched_at IS NULL` rows by `detected_at ASC`. Without cleanup,
// every local re-run of test 1 leaks one undispatched `hash-dispatch-null-*`
// row; once accumulated leaks pass ~49, test 3's freshly-inserted
// `hash-dispatch-sent-*` row falls outside the LIMIT 50 window and
// `dispatched_at` stays NULL even though the function returned `sent >= 1`.
// Filtering on `hash-dispatch-%` keeps deletes test-scoped per CLAUDE.md
// integration-test policy.
//
// SCA-389: the SCA-362 fix above closed leaks from THIS file but not
// from `cost_anomalies_schema_test.ts` (which leaks 5 `testhash_*` rows
// per run with no cleanup). Once those + other unprefixed pollution
// passed 49 across runs, test 3 starved again under the same LIMIT 50
// window. SCA-389 closes the residual hole by pinning the test 3 row's
// `detected_at` to a far-past timestamp — it's now GUARANTEED oldest in
// the table regardless of unrelated leak accumulation. See the test 3
// insert payload comment below.

Deno.test('dispatch: NULL SENTRY_DSN → returns 0, no rows marked dispatched', async () => {
  const svc = serviceClient();
  const uniqHash = 'hash-dispatch-null-' + crypto.randomUUID().slice(0, 8);
  try {
    // Confirm no DSN set locally.
    await svc.from('app_settings').update({ value: null }).eq('key', 'SENTRY_DSN');

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
  } finally {
    // SCA-362: drop this run's row so it doesn't accumulate as a permanent
    // `dispatched_at IS NULL` artifact that pushes test 3's row outside
    // the LIMIT 50 window across re-runs.
    await svc.from('cost_anomalies').delete().eq('canonical_user_key_hash', uniqHash);
  }
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
  const uniqHash = 'hash-dispatch-sent-' + crypto.randomUUID().slice(0, 8);
  try {
    // SCA-362: defensive cleanup of any leaked `hash-dispatch-%` rows from
    // prior runs. Without this, accumulated `hash-dispatch-null-*` artifacts
    // from pre-fix runs can still bump this test's row out of the LIMIT 50
    // window. The `try`/`finally` cleanup added by SCA-362 prevents future
    // leaks; this top-of-test sweep heals existing state for already-leaky
    // dev DBs.
    await svc.from('cost_anomalies').delete().like('canonical_user_key_hash', 'hash-dispatch-%');

    await svc.from('app_settings').update({
      value: 'https://abcdef1234567890@o0000000.ingest.sentry.io/1234567',
    }).eq('key', 'SENTRY_DSN');

    await svc.from('cost_anomalies').insert({
      canonical_user_key_hash: uniqHash,
      anomaly_type: 'daily_spend_hard_cap',
      severity: 'critical',
      details_json: { spend_24h_usd: 12.5 },
      // SCA-389: pin `detected_at` to a far-past timestamp so this row
      // is GUARANTEED to be the oldest `dispatched_at IS NULL` row in
      // the table. The dispatcher picks 50 OLDEST by `detected_at ASC`;
      // with this pin, the test row is always #1 regardless of how
      // much pollution other test files have leaked into local
      // `cost_anomalies`. Closes the SCA-362 starvation hole that
      // re-opened once `cost_anomalies_schema_test.ts`'s 5 leaked
      // `testhash_*` rows per run accumulated past the LIMIT 50 - 1
      // threshold. The `try/finally` cleanup below still drops this
      // row at end-of-test, so the pin is invisible across runs.
      detected_at: new Date('2020-01-01T00:00:00Z').toISOString(),
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
    // SCA-362: drop the inserted row so it doesn't accumulate as state.
    await svc.from('cost_anomalies').delete().eq('canonical_user_key_hash', uniqHash);
  }
});
