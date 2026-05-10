// SCA-296 regression coverage for the two 🔴 /review-5 critical findings
// in the push-send stack:
//
//   C1 — pgmq-dispatch/index.ts maybeSendImportCompletionPush wrote
//        installRow.apns_environment (nullable) into payload_json.environment.
//        PushSendPayloadSchema.environment is z.enum(['production','sandbox']);
//        a null/non-enum value passes the enqueue (notification_jobs.
//        payload_json is jsonb, no shape check) but burns MAX_ATTEMPTS=3
//        attempts inside processPushSend before dead-lettering. Net: a
//        real user push silently dropped because a column we control was
//        never populated. Fix: validate apns_environment at enqueue time;
//        log push_env_missing and skip enqueue when missing.
//
//   C2 — pgmq-dispatch/push_send.ts processPushSend's two .update() calls
//        (success branch + bad_device_token branch) awaited the response
//        without destructuring `error`. A transient DB blip after a
//        successful APNs send leaves the row at state='processing'; the
//        reclaim sweep then re-claims it and APNs gets a duplicate
//        delivery. Fix: destructure { error } and log
//        job_mark_complete_failed; for the bad_device_token branch
//        re-throw so the outer retry loop catches it.
//
// Both fixes are narrowly scoped — these tests pin the exact behaviors
// the /review-5 finding flagged. The sibling test file
// pgmq_dispatch_push_send_test.ts continues to exercise the happy path
// + APNs failure-classification matrix.

import '../_helpers/env.ts';
import { assertEquals, assertRejects } from '@std/assert';
import { serviceClient } from '../_helpers/pg.ts';
import { processPushSend, type PushSendJob, validatePushEnvironment } from '../../functions/pgmq-dispatch/push_send.ts';
import { _setApnsFetchOverrideForTests, sendAPNsPush } from '../../functions/_shared/apns.ts';
import { scriptableApnsFetch } from '../_helpers/mock-apns-server.ts';
import * as jose from 'jose';

// APNs config (same throwaway-key pattern as apns_test.ts / sibling file).
const { privateKey } = await jose.generateKeyPair('ES256', { extractable: true });
const pkcs8Pem = await jose.exportPKCS8(privateKey);
Deno.env.set('APNS_AUTH_KEY_P8', btoa(pkcs8Pem));
Deno.env.set('APNS_AUTH_KEY_ID', 'TEST1234KEY');
Deno.env.set('APNS_TEAM_ID', 'TEAM0123ABC');
Deno.env.set('APNS_BUNDLE_ID', 'com.company.stir.dev');

const DISPATCH_URL = Deno.env.get('PGMQ_DISPATCH_URL') ??
  'http://127.0.0.1:54321/functions/v1/pgmq-dispatch';

interface CapturedLog {
  level: 'info' | 'warn';
  msg: string;
  fields: Record<string, unknown> | undefined;
}

/** Logger stub that records every call so tests can assert log lines fired. */
function capturingLogger(): {
  log: {
    info: (msg: string, fields?: Record<string, unknown>) => void;
    warn: (msg: string, fields?: Record<string, unknown>) => void;
  };
  entries: CapturedLog[];
} {
  const entries: CapturedLog[] = [];
  return {
    entries,
    log: {
      info: (msg, fields) => entries.push({ level: 'info', msg, fields }),
      warn: (msg, fields) => entries.push({ level: 'warn', msg, fields }),
    },
  };
}

function randomApnsToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, '0')).join('');
}

// -----------------------------------------------------------------------------
// C1 regression — enqueue-time apns_environment validation
// -----------------------------------------------------------------------------
//
// The C1 fix lives in maybeSendImportCompletionPush (pgmq-dispatch/
// index.ts) and depends on the validatePushEnvironment helper exported
// from push_send.ts. We test the helper directly: it is the load-bearing
// piece, and a regression here would re-introduce the null-pass-through
// that burned MAX_ATTEMPTS=3 attempts on every recipe-import completion
// push.
//
// Reverting the C1 patch (e.g. returning `raw as any` or removing the
// enum gate) is what this test catches.

Deno.test('SCA-296 C1: validatePushEnvironment passes only the z.enum values', () => {
  assertEquals(validatePushEnvironment('production'), 'production');
  assertEquals(validatePushEnvironment('sandbox'), 'sandbox');
});

Deno.test('SCA-296 C1: validatePushEnvironment rejects null/undefined/empty/garbage', () => {
  // The exact failure mode the fix targets: device_installations.
  // apns_environment column is nullable; .maybeSingle() returns null
  // for the column when not registered via /v1/push/register.
  assertEquals(validatePushEnvironment(null), null);
  assertEquals(validatePushEnvironment(undefined), null);
  assertEquals(validatePushEnvironment(''), null);
  // Wrong case / typo / development is rejected too — only the two
  // canonical values that PushSendPayloadSchema.environment accepts
  // pass through.
  assertEquals(validatePushEnvironment('Production'), null);
  assertEquals(validatePushEnvironment('SANDBOX'), null);
  assertEquals(validatePushEnvironment('development'), null);
  assertEquals(validatePushEnvironment('staging'), null);
});

Deno.test(
  'SCA-296 C1 integration: push-send schema does NOT catch a null environment (proves guard must live at the writer)',
  async () => {
    // Belt-and-suspenders: if a future refactor moves the guard from
    // the writer to "let the schema reject it," that's WORSE — the row
    // gets inserted, claimed, and burns MAX_ATTEMPTS=3 attempts before
    // dead-lettering. We assert the DB shape is unchanged: jsonb accepts
    // any payload, so the only place to catch a null environment is the
    // enqueue site (which the helper above gates).
    const svc = serviceClient();
    const canonicalKey = `ck:test:sca296c1:${crypto.randomUUID()}`;
    const installationId = crypto.randomUUID();
    const apnsToken = randomApnsToken();
    await svc.from('app_users').insert({
      canonical_user_key: canonicalKey,
      current_install_id: installationId,
      revenuecat_app_user_id: canonicalKey,
      source_type: 'cloudkit',
      status: 'active',
    });
    try {
      const { error: probeErr } = await svc.from('notification_jobs').insert({
        canonical_user_key: canonicalKey,
        kind: 'push_send',
        state: 'pending',
        payload_json: {
          template: 'import_completion',
          title: 'probe',
          body: 'probe',
          deep_link: 'stir://import/x',
          apns_token: apnsToken,
          environment: null,
        },
      });
      // The DB accepts the malformed row. This is the failure mode the
      // C1 guard prevents at the writer; if a future migration added a
      // jsonb CHECK constraint this assertion would flip and the C1
      // unit test above becomes belt-only.
      assertEquals(probeErr, null);
    } finally {
      await svc.from('app_users').delete().eq('canonical_user_key', canonicalKey);
    }
  },
);

// -----------------------------------------------------------------------------
// C2 regression — UPDATE-error handling in processPushSend
// -----------------------------------------------------------------------------
//
// We build a wrapped service client whose `from('notification_jobs').update(...)`
// returns a synthetic PostgrestError. After a successful APNs send (success
// branch), the row UPDATE failure must surface as a job_mark_complete_failed
// log line (info/warn). For the bad_device_token branch the wrapped client
// must trigger a re-throw so the outer dispatcher retry loop catches it —
// previously the error was silently swallowed.

type AnyClient = ReturnType<typeof serviceClient>;

interface ErrorInjection {
  /** When true, the next `from(table).update(...)` call returns this error. */
  table: string;
  error: { message: string; details?: string; hint?: string; code?: string };
}

/** Wrap the real service client so a single `update(...)` call on a named
 *  table returns a synthetic Supabase error. All other reads/writes
 *  passthrough to the real client. The injection fires exactly once
 *  (FIFO) to model a transient blip — subsequent retries succeed. */
function clientWithUpdateError(
  real: AnyClient,
  inject: ErrorInjection,
): AnyClient {
  let used = false;
  const wrappedFrom = (table: string) => {
    const realQuery = real.from(table);
    if (table !== inject.table || used) return realQuery;
    return new Proxy(realQuery, {
      get(target, prop, receiver) {
        if (prop === 'update') {
          return (...args: unknown[]) => {
            // Return an object whose .eq() resolves to { data: null, error: ... }.
            // Mirrors the PostgrestFilterBuilder shape processPushSend awaits.
            // deno-lint-ignore no-explicit-any
            const builder: any = (target as any).update(...args);
            // Patch .eq so the first .eq() short-circuits to the injected error.
            const origEq = builder.eq.bind(builder);
            builder.eq = (...eqArgs: unknown[]) => {
              if (used) return origEq(...eqArgs);
              used = true;
              return Promise.resolve({ data: null, error: inject.error });
            };
            return builder;
          };
        }
        return Reflect.get(target, prop, receiver);
      },
    });
  };
  return new Proxy(real, {
    get(target, prop, receiver) {
      if (prop === 'from') return wrappedFrom;
      return Reflect.get(target, prop, receiver);
    },
  }) as AnyClient;
}

interface SeededFixture {
  canonicalKey: string;
  installationId: string;
  apnsToken: string;
  jobId: string;
}

async function seedFixture(
  template: 'reactivation' | 'import_completion' | 'cook_reminder' | 'billing_grace',
): Promise<SeededFixture> {
  const svc = serviceClient();
  const canonicalKey = `ck:test:sca296c2:${crypto.randomUUID()}`;
  const installationId = crypto.randomUUID();
  const apnsToken = randomApnsToken();

  await svc.from('app_users').insert({
    canonical_user_key: canonicalKey,
    current_install_id: installationId,
    revenuecat_app_user_id: canonicalKey,
    source_type: 'cloudkit',
    status: 'active',
  });
  await svc.from('device_installations').insert({
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
  const { data: jobRow, error: jobErr } = await svc
    .from('notification_jobs')
    .insert({
      canonical_user_key: canonicalKey,
      kind: 'push_send',
      state: 'processing',
      attempt_count: 1,
      payload_json: {
        template,
        title: 'SCA-296 C2 test',
        body: 'regression coverage',
        deep_link: 'stir://tonight',
        apns_token: apnsToken,
        environment: 'sandbox',
      },
    })
    .select('id')
    .single();
  if (jobErr || !jobRow) throw new Error(`seed failed: ${jobErr?.message}`);
  return { canonicalKey, installationId, apnsToken, jobId: jobRow.id };
}

async function cleanupFixture(canonicalKey: string): Promise<void> {
  await serviceClient().from('app_users').delete().eq('canonical_user_key', canonicalKey);
}

Deno.test(
  'SCA-296 C2 success-branch: notification_jobs UPDATE error → job_mark_complete_failed log, no throw (APNs already delivered)',
  async () => {
    const fx = await seedFixture('reactivation');
    const mock = scriptableApnsFetch();
    mock.queueOk('apns-id-c2-success');
    _setApnsFetchOverrideForTests(mock.fetch);

    const { log, entries } = capturingLogger();
    const wrapped = clientWithUpdateError(serviceClient(), {
      table: 'notification_jobs',
      error: { message: 'transient connection reset', code: '57P01' },
    });

    try {
      const job: PushSendJob = {
        id: fx.jobId,
        canonical_user_key: fx.canonicalKey,
        kind: 'push_send',
        state: 'processing',
        attempt_count: 1,
        payload_json: {
          template: 'reactivation',
          title: 'SCA-296 C2 test',
          body: 'regression coverage',
          deep_link: 'stir://tonight',
          apns_token: fx.apnsToken,
          environment: 'sandbox',
        },
      };

      // MUST NOT throw — APNs accepted the push, and re-throwing here
      // would cause the outer retry loop to issue a SECOND delivery on
      // the reclaim. Strictly worse than the (rare) duplicate from the
      // reclaim sweep firing on the un-marked row.
      await processPushSend(wrapped, job, log, sendAPNsPush);

      // APNs got exactly one delivery.
      assertEquals(mock.calls.length, 1);

      // The warning log line fired with the right shape.
      const warned = entries.find((e) => e.msg === 'job_mark_complete_failed');
      if (!warned) {
        throw new Error(
          `expected job_mark_complete_failed log line; got: ${JSON.stringify(entries)}`,
        );
      }
      assertEquals(warned.level, 'warn');
      assertEquals(warned.fields?.['branch'], 'push_sent');
      assertEquals(warned.fields?.['job_id'], fx.jobId);
    } finally {
      _setApnsFetchOverrideForTests(null);
      await cleanupFixture(fx.canonicalKey);
    }
  },
);

Deno.test(
  'SCA-296 C2 bad_device_token branch: notification_jobs UPDATE error → throws (retry catches; idempotent on second pass)',
  async () => {
    const fx = await seedFixture('import_completion');
    const mock = scriptableApnsFetch();
    mock.queueError(410, 'Unregistered');
    _setApnsFetchOverrideForTests(mock.fetch);

    const { log, entries } = capturingLogger();
    const wrapped = clientWithUpdateError(serviceClient(), {
      table: 'notification_jobs',
      error: { message: 'transient pool exhausted', code: '53300' },
    });

    try {
      const job: PushSendJob = {
        id: fx.jobId,
        canonical_user_key: fx.canonicalKey,
        kind: 'push_send',
        state: 'processing',
        attempt_count: 1,
        payload_json: {
          template: 'import_completion',
          title: 'SCA-296 C2 test',
          body: 'regression coverage',
          deep_link: 'stir://tonight',
          apns_token: fx.apnsToken,
          environment: 'sandbox',
        },
      };

      // MUST throw — APNs rejected the token; the row is still at
      // state='processing'. The pre-fix code returned silently, leaving
      // the row orphaned for the reclaim sweep to re-issue. Throwing
      // surfaces to the outer dispatcher loop which schedules a retry;
      // the second pass's sendAPNsPush will get bad_device_token again
      // and null the token then — idempotent.
      await assertRejects(
        () => processPushSend(wrapped, job, log, sendAPNsPush),
        Error,
        'notification_jobs UPDATE failed',
      );

      assertEquals(mock.calls.length, 1);

      // The warning log line landed first, before the throw.
      const warned = entries.find((e) => e.msg === 'job_mark_complete_failed');
      if (!warned) {
        throw new Error(
          `expected job_mark_complete_failed log line; got: ${JSON.stringify(entries)}`,
        );
      }
      assertEquals(warned.level, 'warn');
      assertEquals(warned.fields?.['branch'], 'bad_device_token');
    } finally {
      _setApnsFetchOverrideForTests(null);
      await cleanupFixture(fx.canonicalKey);
    }
  },
);
