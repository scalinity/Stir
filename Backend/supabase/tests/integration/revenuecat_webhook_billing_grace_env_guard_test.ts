// SCA-327 regression coverage — second site of the SCA-296 C1 bug class.
//
// device_installations.apns_environment is nullable (the CHECK only
// constrains non-null values to 'production'|'sandbox'). The
// revenuecat-webhook BILLING_ISSUE enqueue path read it directly into
// payload_json.environment and wrote two notification_jobs rows whose
// downstream PushSendPayloadSchema.environment z.enum(['production',
// 'sandbox']) check would reject them — burning MAX_ATTEMPTS=3 attempts
// inside processPushSend before dead-lettering. Net: a real
// BILLING_ISSUE push silently dropped because a column we control was
// never populated.
//
// The SCA-327 fix hoists validatePushEnvironment to _shared/apns.ts
// (was: pgmq-dispatch/push_send.ts; the function is now imported from
// both writers) and applies the guard in enqueueBillingGracePushes:
// validate at enqueue time, log push_env_missing at warn, skip enqueue
// on null. This file pins that behavior at the HTTP boundary.
//
// Note on test surface: the equivalent of pgmq-dispatch's processPushSend
// is not directly invokable from the revenuecat-webhook code path
// (enqueueBillingGracePushes is a private function inside index.ts). We
// drive the webhook over HTTP and verify the storage side: zero
// `notification_jobs` rows inserted when `apns_environment` is NULL on
// the most-recent device_installations row.

import '../_helpers/env.ts';
import { assertEquals, assertExists } from '@std/assert';
import { serviceClient } from '../_helpers/pg.ts';
import { quickBootstrap } from '../_helpers/factory.ts';

const WEBHOOK_URL = `${
  Deno.env.get('SUPABASE_URL') ?? 'http://127.0.0.1:54321'
}/functions/v1/revenuecat-webhook`;
const WEBHOOK_SECRET = Deno.env.get('REVENUECAT_WEBHOOK_SECRET') ??
  'local-dev-rc-webhook-secret-do-not-use-in-prod';

interface RcEventPayload {
  event: {
    id: string;
    type: string;
    app_user_id: string;
    product_id?: string;
    period_type?: string;
    expiration_at_ms?: number | null;
    environment?: 'SANDBOX' | 'PRODUCTION';
  };
  api_version: string;
}

function rcEvent(
  type: string,
  overrides: Partial<RcEventPayload['event']> = {},
): RcEventPayload {
  return {
    api_version: '1.0',
    event: {
      id: overrides.id ?? `evt_${crypto.randomUUID()}`,
      type,
      app_user_id: overrides.app_user_id ?? `install:${crypto.randomUUID()}`,
      environment: overrides.environment ?? 'SANDBOX',
      ...overrides,
    },
  };
}

async function postWebhook(payload: unknown): Promise<{ status: number }> {
  const response = await fetch(WEBHOOK_URL, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'Authorization': WEBHOOK_SECRET,
    },
    body: JSON.stringify(payload),
  });
  // Drain the body to free the connection.
  await response.text();
  return { status: response.status };
}

function randomApnsToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, '0')).join('');
}

// -----------------------------------------------------------------------------
// SCA-327 regression — BILLING_ISSUE with null apns_environment never enqueues
// -----------------------------------------------------------------------------

Deno.test(
  'SCA-327: BILLING_ISSUE + device with apns_environment=NULL → zero notification_jobs inserted',
  async () => {
    const bs = await quickBootstrap();
    const svc = serviceClient();

    // Insert a device row with notifications enabled but apns_environment
    // missing — exactly the shape an upgraded-without-reinstall user
    // produces if /v1/push/register hasn't fired since the column was
    // added. The webhook reads this row via .maybeSingle() ordered by
    // last_seen_at DESC.
    const installationId = bs.canonical_user_key.startsWith('install:')
      ? bs.canonical_user_key.slice('install:'.length)
      : crypto.randomUUID();
    const apnsToken = randomApnsToken();
    const { error: insErr } = await svc.from('device_installations').upsert({
      installation_id: installationId,
      canonical_user_key: bs.canonical_user_key,
      build: '1.0.0 (1)',
      os_version: '17.5',
      push_token: apnsToken,
      notifications_enabled: true,
      apns_environment: null,
      notification_prefs_json: {
        reactivation: true,
        import_completion: true,
        cook_reminder: true,
        billing_grace: true,
      },
      last_seen_at: new Date().toISOString(),
    });
    assertEquals(insErr, null, `device_installations seed failed: ${insErr?.message}`);

    // Seed an active premium entitlement so the BILLING_ISSUE transition
    // (active → grace) is a real state change and reaches the
    // enqueueBillingGracePushes call site.
    const initial = await postWebhook(rcEvent('INITIAL_PURCHASE', {
      app_user_id: bs.canonical_user_key,
      product_id: 'stir.premium.monthly',
      period_type: 'NORMAL',
      expiration_at_ms: Date.UTC(2026, 5, 19),
    }));
    assertEquals(initial.status, 200);

    // BILLING_ISSUE — the path under test. Pre-fix this would have
    // inserted two notification_jobs rows with payload_json.environment
    // = null; post-fix the writer logs push_env_missing + returns early.
    const issue = await postWebhook(rcEvent('BILLING_ISSUE', {
      app_user_id: bs.canonical_user_key,
      product_id: 'stir.premium.monthly',
      expiration_at_ms: Date.UTC(2026, 5, 19),
    }));
    assertEquals(issue.status, 200);

    // Sanity: the billing_state DID transition to grace (the
    // entitlement_snapshots side is unaffected by the push-enqueue
    // guard; only the notification_jobs writes are gated).
    const { data: entRow } = await svc
      .from('entitlement_snapshots')
      .select('billing_state')
      .eq('canonical_user_key', bs.canonical_user_key)
      .maybeSingle();
    assertExists(entRow);
    assertEquals(entRow.billing_state, 'grace');

    // Core assertion: zero pending billing_grace rows for this canonical
    // key. Filter scoped to the test's canonical_user_key — never
    // aggregate-style (CLAUDE.md "Integration test DB strategy").
    const { data: jobs, error: jobsErr } = await svc
      .from('notification_jobs')
      .select('id, payload_json')
      .eq('canonical_user_key', bs.canonical_user_key)
      .eq('kind', 'push_send')
      .filter('payload_json->>template', 'eq', 'billing_grace');
    assertEquals(jobsErr, null, `notification_jobs read failed: ${jobsErr?.message}`);
    assertEquals(
      jobs?.length ?? 0,
      0,
      `expected zero billing_grace push rows when apns_environment is NULL; got: ${
        JSON.stringify(jobs)
      }`,
    );
  },
);
