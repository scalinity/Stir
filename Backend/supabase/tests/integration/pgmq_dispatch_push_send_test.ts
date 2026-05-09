// SCA-115 — integration coverage of `processPushSend` against a real
// Postgres + a mock APNs fetch DI seam.
//
// Replaces the reverted scaffold (`pgmq_dispatch_push_send_test.ts`)
// whose `STIR_RUN_APNS_INTEGRATION=1 && STIR_APNS_MOCK_URL` gate silently
// skipped every assertion. This file runs by default — no env gate, no
// silent skip; if the local Supabase stack is unreachable the test fails
// loudly via the seed insert, which is the correct posture (SCA-115
// acceptance: "No silent-skip gates — tests run by default in CI").
//
// What this test exercises:
//   - 200 happy path: notification_jobs.state flips to 'completed',
//     processed_at set, no device_installations mutation.
//   - 410 Unregistered: job marked completed (token is dead, not our bug)
//     AND device_installations.push_token nulled out, notifications_enabled
//     set to false.
//   - 503 server_error: processPushSend throws, surfacing as a
//     retryable failure to the outer dispatcher loop. Job row is left
//     untouched in 'processing' (the outer loop's catch handles retry
//     scheduling — that path is covered by pgmq_dispatch_reclaim_test).
//
// Pattern: scriptable APNs fetch is installed via
// `_setApnsFetchOverrideForTests`, processPushSend is called directly
// (it's exported from pgmq-dispatch/push_send.ts), Postgres state is
// observed through the service-role PostgREST client. No HTTP round-trip
// to the edge runtime — that path is covered by the reclaim test.

import '../_helpers/env.ts';
import { assertEquals, assertRejects } from '@std/assert';
import { serviceClient } from '../_helpers/pg.ts';
import { processPushSend, type PushSendJob } from '../../functions/pgmq-dispatch/push_send.ts';
import { _setApnsFetchOverrideForTests, sendAPNsPush } from '../../functions/_shared/apns.ts';
import { scriptableApnsFetch } from '../_helpers/mock-apns-server.ts';
import * as jose from 'jose';

// Provide ES256 APNs config for the test run. `sendAPNsPush` needs to be
// able to mint a provider JWT before issuing the (mocked) fetch — without
// these env vars the mint fails before the fetch override even kicks in.
// Same throwaway-key pattern as apns_test.ts / apns_hardening_test.ts.
const { privateKey } = await jose.generateKeyPair('ES256', { extractable: true });
const pkcs8Pem = await jose.exportPKCS8(privateKey);
Deno.env.set('APNS_AUTH_KEY_P8', btoa(pkcs8Pem));
Deno.env.set('APNS_AUTH_KEY_ID', 'TEST1234KEY');
Deno.env.set('APNS_TEAM_ID', 'TEAM0123ABC');
Deno.env.set('APNS_BUNDLE_ID', 'com.company.stir.dev');

// Quiet stand-in for createLogger — processPushSend only invokes log.info.
// Capturing into an array lets a test assert a particular log line landed
// when needed, but most tests don't bother.
function quietLogger(): { info: (msg: string, fields?: Record<string, unknown>) => void } {
  return { info: () => {} };
}

/** Hex-shaped 64-char APNs token. PushSendPayloadSchema rejects anything
 *  else. We generate a random hex per test so seeded device_installations
 *  rows don't collide across tests. */
function randomApnsToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, '0')).join('');
}

interface SeededFixture {
  canonicalKey: string;
  installationId: string;
  apnsToken: string;
  jobId: string;
}

/** Seed an app_user + device_installation + notification_jobs(push_send)
 *  row keyed on a unique test-scoped canonical_user_key. Returns the
 *  identifiers the test will assert on later. */
async function seedFixture(
  opts: { template: 'reactivation' | 'import_completion' | 'cook_reminder' | 'billing_grace' } = {
    template: 'reactivation',
  },
): Promise<SeededFixture> {
  const svc = serviceClient();
  const canonicalKey = `ck:test:sca115:${crypto.randomUUID()}`;
  const installationId = crypto.randomUUID();
  const apnsToken = randomApnsToken();

  // FK chain: notification_jobs → app_users; device_installations → app_users.
  const { error: userErr } = await svc.from('app_users').insert({
    canonical_user_key: canonicalKey,
    current_install_id: installationId,
    revenuecat_app_user_id: canonicalKey,
    source_type: 'cloudkit',
    status: 'active',
  });
  if (userErr) throw new Error(`seedFixture app_users insert failed: ${userErr.message}`);

  const { error: installErr } = await svc.from('device_installations').insert({
    installation_id: installationId,
    canonical_user_key: canonicalKey,
    build: '1.0.0 (1)',
    os_version: '17.5',
    push_token: apnsToken,
    notifications_enabled: true,
    apns_environment: 'sandbox',
    notification_prefs_json: {
      reactivation: true,
      import_completion: true,
      cook_reminder: true,
      billing_grace: true,
    },
  });
  if (installErr) {
    throw new Error(`seedFixture device_installations insert failed: ${installErr.message}`);
  }

  const { data: jobRow, error: jobErr } = await svc
    .from('notification_jobs')
    .insert({
      canonical_user_key: canonicalKey,
      kind: 'push_send',
      state: 'processing', // processPushSend is invoked AFTER the dispatcher claims the row
      attempt_count: 1,
      payload_json: {
        template: opts.template,
        title: 'SCA-115 test',
        body: 'integration coverage',
        deep_link: 'stir://tonight',
        apns_token: apnsToken,
        environment: 'sandbox',
      },
    })
    .select('id')
    .single();
  if (jobErr || !jobRow) {
    throw new Error(`seedFixture notification_jobs insert failed: ${jobErr?.message}`);
  }

  return { canonicalKey, installationId, apnsToken, jobId: jobRow.id };
}

/** Hard-delete the rows seeded by `seedFixture` (FK cascade handles
 *  device_installations + notification_jobs). Test-scoped key prefix
 *  guards against accidental cross-test bleed if cleanup is skipped. */
async function cleanupFixture(canonicalKey: string): Promise<void> {
  const svc = serviceClient();
  await svc.from('app_users').delete().eq('canonical_user_key', canonicalKey);
}

/** Build a PushSendJob shape from a seeded fixture, mirroring what the
 *  dispatcher's claim RPC would return. */
async function loadJob(jobId: string): Promise<PushSendJob> {
  const svc = serviceClient();
  const { data, error } = await svc
    .from('notification_jobs')
    .select('id, canonical_user_key, kind, state, attempt_count, payload_json')
    .eq('id', jobId)
    .single();
  if (error || !data) throw new Error(`loadJob failed: ${error?.message}`);
  return data as PushSendJob;
}

Deno.test('SCA-115 processPushSend: 200 → job=completed, device_installation untouched', async () => {
  const fx = await seedFixture({ template: 'reactivation' });
  const mock = scriptableApnsFetch();
  mock.queueOk('apns-id-200-happy');
  _setApnsFetchOverrideForTests(mock.fetch);

  try {
    const job = await loadJob(fx.jobId);
    await processPushSend(serviceClient(), job, quietLogger(), sendAPNsPush);

    // Mock fetch saw exactly one call to the sandbox APNs endpoint.
    assertEquals(mock.calls.length, 1);
    assertEquals(
      mock.calls[0]!.url,
      `https://api.sandbox.push.apple.com/3/device/${fx.apnsToken}`,
    );
    // Header shape: bearer JWT + apns-topic + apns-collapse-id=template.
    const headers = mock.calls[0]!.headers;
    assertEquals(headers['apns-topic'], 'com.company.stir.dev');
    assertEquals(headers['apns-push-type'], 'alert');
    assertEquals(headers['apns-collapse-id'], 'reactivation');
    if (!(headers['authorization'] ?? '').startsWith('bearer ')) {
      throw new Error(`expected bearer JWT, got: ${headers['authorization']}`);
    }

    // Job flipped to completed.
    const svc = serviceClient();
    const { data: jobAfter } = await svc
      .from('notification_jobs')
      .select('state, processed_at, error_message')
      .eq('id', fx.jobId)
      .single();
    assertEquals(jobAfter?.state, 'completed');
    if (!jobAfter?.processed_at) throw new Error('processed_at must be set after success');
    assertEquals(jobAfter?.error_message, null);

    // Device installation is untouched on success.
    const { data: installAfter } = await svc
      .from('device_installations')
      .select('push_token, notifications_enabled')
      .eq('installation_id', fx.installationId)
      .single();
    assertEquals(installAfter?.push_token, fx.apnsToken);
    assertEquals(installAfter?.notifications_enabled, true);
  } finally {
    _setApnsFetchOverrideForTests(null);
    await cleanupFixture(fx.canonicalKey);
  }
});

Deno.test('SCA-115 processPushSend: 410 Unregistered → job=completed, push_token nulled', async () => {
  const fx = await seedFixture({ template: 'import_completion' });
  const mock = scriptableApnsFetch();
  mock.queueError(410, 'Unregistered');
  _setApnsFetchOverrideForTests(mock.fetch);

  try {
    const job = await loadJob(fx.jobId);
    await processPushSend(serviceClient(), job, quietLogger(), sendAPNsPush);

    assertEquals(mock.calls.length, 1);

    const svc = serviceClient();

    // Job flips to completed (a dead token is not retryable; the row is
    // terminal). error_message records the APNs reason for the audit
    // trail.
    const { data: jobAfter } = await svc
      .from('notification_jobs')
      .select('state, processed_at, error_message')
      .eq('id', fx.jobId)
      .single();
    assertEquals(jobAfter?.state, 'completed');
    if (!jobAfter?.processed_at) {
      throw new Error('processed_at must be set after dead-token completion');
    }
    if (!(jobAfter?.error_message ?? '').includes('Unregistered')) {
      throw new Error(`error_message must mention Unregistered; got: ${jobAfter?.error_message}`);
    }

    // Device installation: push_token nulled, notifications_enabled
    // flipped to false so future enqueues skip this device.
    const { data: installAfter } = await svc
      .from('device_installations')
      .select('push_token, notifications_enabled')
      .eq('installation_id', fx.installationId)
      .single();
    assertEquals(installAfter?.push_token, null);
    assertEquals(installAfter?.notifications_enabled, false);
  } finally {
    _setApnsFetchOverrideForTests(null);
    await cleanupFixture(fx.canonicalKey);
  }
});

Deno.test('SCA-115 processPushSend: 503 server_error → throws (caller schedules retry)', async () => {
  const fx = await seedFixture({ template: 'cook_reminder' });
  const mock = scriptableApnsFetch();
  mock.queueError(503, 'ServiceUnavailable');
  _setApnsFetchOverrideForTests(mock.fetch);

  try {
    const job = await loadJob(fx.jobId);

    // 503 is the canonical "APNs is having a moment" path; processPushSend
    // throws to surface to the outer dispatcher's retry-scheduling loop.
    // The error message embeds reason + status for log-grep.
    await assertRejects(
      () => processPushSend(serviceClient(), job, quietLogger(), sendAPNsPush),
      Error,
      'reason=server_error',
    );

    assertEquals(mock.calls.length, 1);

    const svc = serviceClient();

    // Job is NOT marked completed/failed by processPushSend on a thrown
    // path — the outer dispatcher loop owns retry scheduling. The state
    // remains whatever the seed set ('processing') because processPushSend
    // never wrote to the row. This guards against a future regression
    // that mistakenly marks throw-path failures as terminal here.
    const { data: jobAfter } = await svc
      .from('notification_jobs')
      .select('state, processed_at, error_message')
      .eq('id', fx.jobId)
      .single();
    assertEquals(jobAfter?.state, 'processing');
    assertEquals(jobAfter?.processed_at, null);
    assertEquals(jobAfter?.error_message, null);

    // Device installation untouched on retryable failure.
    const { data: installAfter } = await svc
      .from('device_installations')
      .select('push_token, notifications_enabled')
      .eq('installation_id', fx.installationId)
      .single();
    assertEquals(installAfter?.push_token, fx.apnsToken);
    assertEquals(installAfter?.notifications_enabled, true);
  } finally {
    _setApnsFetchOverrideForTests(null);
    await cleanupFixture(fx.canonicalKey);
  }
});

Deno.test('SCA-115 processPushSend: 400 BadDeviceToken → job=completed, push_token nulled', async () => {
  // Belt-and-suspenders for the apns.ts review C4 fix: 400 with explicit
  // BadDeviceToken reason flows through the bad_device_token branch
  // (token nulled), NOT the catch-all 400 → config_invalid throw branch.
  // Pre-fix every 400 would null healthy tokens; a regression here would
  // mean a benign payload bug nukes user push-notification setups.
  const fx = await seedFixture({ template: 'billing_grace' });
  const mock = scriptableApnsFetch();
  mock.queueError(400, 'BadDeviceToken');
  _setApnsFetchOverrideForTests(mock.fetch);

  try {
    const job = await loadJob(fx.jobId);
    await processPushSend(serviceClient(), job, quietLogger(), sendAPNsPush);

    const svc = serviceClient();
    const { data: installAfter } = await svc
      .from('device_installations')
      .select('push_token, notifications_enabled')
      .eq('installation_id', fx.installationId)
      .single();
    assertEquals(installAfter?.push_token, null);
    assertEquals(installAfter?.notifications_enabled, false);

    const { data: jobAfter } = await svc
      .from('notification_jobs')
      .select('state, error_message')
      .eq('id', fx.jobId)
      .single();
    assertEquals(jobAfter?.state, 'completed');
    if (!(jobAfter?.error_message ?? '').includes('BadDeviceToken')) {
      throw new Error(`error_message must mention BadDeviceToken; got: ${jobAfter?.error_message}`);
    }
  } finally {
    _setApnsFetchOverrideForTests(null);
    await cleanupFixture(fx.canonicalKey);
  }
});

Deno.test('SCA-115 processPushSend: 400 PayloadTooLarge → throws (config_invalid, NOT dead token)', async () => {
  // Companion to the BadDeviceToken case: a non-BadDeviceToken 400 must
  // surface as a config_invalid throw (page ops, don't kill the token).
  const fx = await seedFixture({ template: 'reactivation' });
  const mock = scriptableApnsFetch();
  mock.queueError(400, 'PayloadTooLarge');
  _setApnsFetchOverrideForTests(mock.fetch);

  try {
    const job = await loadJob(fx.jobId);
    await assertRejects(
      () => processPushSend(serviceClient(), job, quietLogger(), sendAPNsPush),
      Error,
      'reason=config_invalid',
    );

    // Token MUST NOT be nulled — this is the regression guard.
    const svc = serviceClient();
    const { data: installAfter } = await svc
      .from('device_installations')
      .select('push_token, notifications_enabled')
      .eq('installation_id', fx.installationId)
      .single();
    assertEquals(installAfter?.push_token, fx.apnsToken);
    assertEquals(installAfter?.notifications_enabled, true);
  } finally {
    _setApnsFetchOverrideForTests(null);
    await cleanupFixture(fx.canonicalKey);
  }
});

Deno.test('SCA-115 processPushSend: malformed payload → throws (Zod-validated)', async () => {
  // Belt-and-suspenders for the W24 PushSendPayloadSchema gate. An errant
  // writer inserting a payload missing `apns_token` should surface as a
  // typed-error throw, not crash inside sendAPNsPush.
  const svc = serviceClient();
  const canonicalKey = `ck:test:sca115:${crypto.randomUUID()}`;
  const installationId = crypto.randomUUID();
  await svc.from('app_users').insert({
    canonical_user_key: canonicalKey,
    current_install_id: installationId,
    revenuecat_app_user_id: canonicalKey,
    source_type: 'cloudkit',
    status: 'active',
  });

  const { data: jobRow } = await svc
    .from('notification_jobs')
    .insert({
      canonical_user_key: canonicalKey,
      kind: 'push_send',
      state: 'processing',
      attempt_count: 1,
      payload_json: {
        // missing apns_token + environment
        template: 'reactivation',
        title: 'malformed',
        body: 'payload',
      },
    })
    .select('id')
    .single();
  if (!jobRow) throw new Error('seed insert failed');

  const mock = scriptableApnsFetch();
  // No queued response — if the fetch is reached at all the test fails.
  _setApnsFetchOverrideForTests(mock.fetch);

  try {
    const job = await loadJob(jobRow.id);
    await assertRejects(
      () => processPushSend(svc, job, quietLogger(), sendAPNsPush),
      Error,
      'invalid push_send payload',
    );
    // No fetch was issued (Zod fails BEFORE sendAPNsPush is invoked).
    assertEquals(mock.calls.length, 0);
  } finally {
    _setApnsFetchOverrideForTests(null);
    await cleanupFixture(canonicalKey);
  }
});
