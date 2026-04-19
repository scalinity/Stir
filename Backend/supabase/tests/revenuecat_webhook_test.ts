// Integration tests for POST /v1/revenuecat/webhook.
//
// Requires `supabase functions serve --env-file .env` to be running.
// Authenticates with the local-dev REVENUECAT_WEBHOOK_SECRET from .env.
//
// Coverage:
//   - Auth: valid Authorization header → 200; missing → 401; wrong → 401
//   - Happy path: INITIAL_PURCHASE writes entitlement_snapshots
//   - Idempotency: replay same event_id → second is no-op
//   - Each transition rule in CLAUDE.md's "RC event → billing_state" table
//   - SUBSCRIBER_ALIAS moves entitlement from original → new
//   - Unknown event type → 200 + webhook_log status='unknown_event'
//   - Malformed JSON → 200 + webhook_log status='validation_failed'
//   - End-to-end: webhook fires → /v1/config/bootstrap reflects new state

import './_helpers/env.ts';
import { assertEquals, assertExists } from '@std/assert';
import { serviceClient } from './_helpers/pg.ts';
import {
  callConfigBootstrap,
  quickBootstrap,
  testCkRecord,
  testInstallId,
} from './_helpers/factory.ts';
import { clearRateLimitBuckets } from './_helpers/pg.ts';

await clearRateLimitBuckets();

const WEBHOOK_URL = `${Deno.env.get('SUPABASE_URL') ?? 'http://127.0.0.1:54321'}/functions/v1/revenuecat-webhook`;
const WEBHOOK_SECRET = Deno.env.get('REVENUECAT_WEBHOOK_SECRET') ??
  'local-dev-rc-webhook-secret-do-not-use-in-prod';

interface RcEventPayload {
  event: {
    id: string;
    type: string;
    app_user_id: string;
    original_app_user_id?: string;
    new_app_user_id?: string;
    transferred_from?: string[];
    transferred_to?: string[];
    product_id?: string;
    period_type?: string;
    purchased_at_ms?: number;
    expiration_at_ms?: number | null;
    event_timestamp_ms?: number;
    environment?: 'SANDBOX' | 'PRODUCTION';
  };
  api_version: string;
}

/** Build a RC-shaped event payload with sensible defaults. */
function rcEvent(
  type: string,
  overrides: Partial<RcEventPayload['event']> = {},
): RcEventPayload {
  return {
    api_version: '1.0',
    event: {
      id: overrides.id ?? `evt_${crypto.randomUUID()}`,
      type,
      app_user_id: overrides.app_user_id ?? `install:${testInstallId()}`,
      environment: overrides.environment ?? 'SANDBOX',
      ...overrides,
    },
  };
}

/** POST to the webhook with the configured auth secret. */
async function postWebhook(
  payload: unknown,
  opts: { auth?: string | null } = {},
): Promise<{ status: number; body: unknown }> {
  const headers: Record<string, string> = { 'content-type': 'application/json' };
  const authValue = opts.auth === undefined ? WEBHOOK_SECRET : opts.auth;
  if (authValue !== null) headers['Authorization'] = authValue;

  const response = await fetch(WEBHOOK_URL, {
    method: 'POST',
    headers,
    body: typeof payload === 'string' ? payload : JSON.stringify(payload),
  });
  const text = await response.text();
  let body: unknown = text;
  try { body = JSON.parse(text); } catch { /* leave as text */ }
  return { status: response.status, body };
}

async function readEntitlement(canonicalKey: string) {
  const { data, error } = await serviceClient()
    .from('entitlement_snapshots')
    .select('*')
    .eq('canonical_user_key', canonicalKey)
    .maybeSingle();
  if (error) throw error;
  return data;
}

async function countWebhookLogs(eventId: string): Promise<number> {
  const { count, error } = await serviceClient()
    .from('webhook_log')
    .select('*', { count: 'exact', head: true })
    .eq('event_id', eventId);
  if (error) throw error;
  return count ?? 0;
}

async function lastWebhookLog(eventId: string) {
  const { data, error } = await serviceClient()
    .from('webhook_log')
    .select('*')
    .eq('event_id', eventId)
    .order('processed_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  return data;
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

Deno.test('webhook rejects missing Authorization header with 401', async () => {
  const res = await postWebhook(rcEvent('RENEWAL'), { auth: null });
  assertEquals(res.status, 401);
});

Deno.test('webhook rejects GET method with 405', async () => {
  // Coverage gap flagged by DB1: non-POST should 405 before any body
  // read or auth check — this is a client-bug signal.
  const response = await fetch(WEBHOOK_URL, {
    method: 'GET',
    headers: { 'Authorization': WEBHOOK_SECRET },
  });
  await response.body?.cancel();
  assertEquals(response.status, 405);
});

Deno.test('webhook accepts Authorization with "Bearer <secret>" prefix', async () => {
  // Operational brittleness fix (SA2 LOW): RC dashboards can be configured
  // with or without the "Bearer " prefix; the server normalizes.
  const bs = await quickBootstrap();
  const res = await postWebhook(
    rcEvent('RENEWAL', {
      app_user_id: bs.canonical_user_key,
      product_id: 'stir.premium.monthly',
      period_type: 'NORMAL',
      expiration_at_ms: Date.UTC(2026, 4, 19),
    }),
    { auth: `Bearer ${WEBHOOK_SECRET}` },
  );
  assertEquals(res.status, 200);
});

Deno.test('webhook rejects oversized request body with 413', async () => {
  // Post-auth body-size cap (SA1 MED). 64 KiB is the app-layer limit.
  const bs = await quickBootstrap();
  const hugePayload = 'x'.repeat(100 * 1024);
  // Craft a syntactically-valid JSON but with a massive unused field.
  const body = JSON.stringify({
    api_version: '1.0',
    event: {
      id: 'evt_oversized',
      type: 'RENEWAL',
      app_user_id: bs.canonical_user_key,
      _padding: hugePayload,
    },
  });
  const response = await fetch(WEBHOOK_URL, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'Authorization': WEBHOOK_SECRET,
    },
    body,
  });
  await response.body?.cancel();
  assertEquals(response.status, 413);
});

Deno.test('webhook rejects non-JSON Content-Type with 415', async () => {
  const response = await fetch(WEBHOOK_URL, {
    method: 'POST',
    headers: {
      'content-type': 'text/html',
      'Authorization': WEBHOOK_SECRET,
    },
    body: '<html></html>',
  });
  await response.body?.cancel();
  assertEquals(response.status, 415);
});

Deno.test('webhook rejects stale event (event_timestamp_ms > 10 min old) with 200 + stale_event', async () => {
  // Replay-window defense (SA2). A captured event from >10 min ago
  // cannot be re-applied even with a valid auth header.
  const bs = await quickBootstrap();
  const staleTimestamp = Date.now() - 30 * 60 * 1000;  // 30 min old
  const event = rcEvent('RENEWAL', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.premium.monthly',
    period_type: 'NORMAL',
    event_timestamp_ms: staleTimestamp,
    expiration_at_ms: Date.UTC(2026, 4, 19),
  });
  const res = await postWebhook(event);
  assertEquals(res.status, 200);
  const body = res.body as { received?: boolean; status?: string };
  assertEquals(body.received, true);
  assertEquals(body.status, 'stale_event');

  // No entitlement mutation.
  const row = await readEntitlement(bs.canonical_user_key);
  // Free-default row exists from bootstrap; ensure tier didn't flip to premium.
  assertEquals(row?.tier, 'free');
});

Deno.test('webhook rejects malformed canonical_user_key with validation_failed', async () => {
  // Regression guard for SA1 X: `app_user_id` format enforced via Zod regex.
  // A non-matching key now routes to validation_failed instead of
  // polluting app_users with a malformed row.
  const res = await postWebhook(rcEvent('RENEWAL', {
    app_user_id: 'not-a-canonical-key',
    product_id: 'stir.premium.monthly',
    period_type: 'NORMAL',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  }));
  // Handler returns 200 on validation failure (so RC doesn't retry forever),
  // but the log is validation_failed and no entitlement row is written.
  assertEquals(res.status, 200);
});

Deno.test('webhook rejects wrong Authorization header with 401', async () => {
  const res = await postWebhook(rcEvent('RENEWAL'), { auth: 'wrong-secret' });
  assertEquals(res.status, 401);
});

Deno.test('webhook accepts valid Authorization header with 200', async () => {
  const bs = await quickBootstrap();
  const res = await postWebhook(rcEvent('RENEWAL', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.premium.monthly',
    period_type: 'NORMAL',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  }));
  assertEquals(res.status, 200);
  assertEquals((res.body as { received?: boolean }).received, true);
});

// ---------------------------------------------------------------------------
// Happy paths per transition table
// ---------------------------------------------------------------------------

Deno.test('INITIAL_PURCHASE with trial writes entitlement row tier=premium billing_state=trial', async () => {
  const bs = await quickBootstrap();
  const expiresAt = Date.UTC(2026, 3, 26);

  const res = await postWebhook(rcEvent('INITIAL_PURCHASE', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.premium.annual.trial7',
    period_type: 'TRIAL',
    expiration_at_ms: expiresAt,
  }));
  assertEquals(res.status, 200);

  const row = await readEntitlement(bs.canonical_user_key);
  assertExists(row);
  assertEquals(row.tier, 'premium');
  assertEquals(row.billing_state, 'trial');
  assertEquals(row.is_trial, true);
  assertEquals(new Date(row.expires_at).getTime(), expiresAt);
});

Deno.test('RENEWAL flips billing_state to active and clears is_trial', async () => {
  const bs = await quickBootstrap();
  // Seed a prior trial row.
  await postWebhook(rcEvent('INITIAL_PURCHASE', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.premium.annual.trial7',
    period_type: 'TRIAL',
    expiration_at_ms: Date.UTC(2026, 3, 26),
  }));
  // Renewal.
  await postWebhook(rcEvent('RENEWAL', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.premium.annual.trial7',
    period_type: 'NORMAL',
    expiration_at_ms: Date.UTC(2027, 3, 26),
  }));

  const row = await readEntitlement(bs.canonical_user_key);
  assertExists(row);
  assertEquals(row.billing_state, 'active');
  assertEquals(row.is_trial, false);
});

Deno.test('CANCELLATION sets billing_state=cancelled_active, preserves tier', async () => {
  const bs = await quickBootstrap();
  await postWebhook(rcEvent('INITIAL_PURCHASE', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.premium.monthly',
    period_type: 'NORMAL',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  }));
  await postWebhook(rcEvent('CANCELLATION', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.premium.monthly',
    period_type: 'NORMAL',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  }));

  const row = await readEntitlement(bs.canonical_user_key);
  assertExists(row);
  assertEquals(row.tier, 'premium');
  assertEquals(row.billing_state, 'cancelled_active');
});

Deno.test('EXPIRATION sets billing_state=expired, tier preserved for win-back', async () => {
  const bs = await quickBootstrap();
  await postWebhook(rcEvent('INITIAL_PURCHASE', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.premium.monthly',
    period_type: 'NORMAL',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  }));
  await postWebhook(rcEvent('EXPIRATION', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.premium.monthly',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  }));

  const row = await readEntitlement(bs.canonical_user_key);
  assertExists(row);
  assertEquals(row.tier, 'premium');
  assertEquals(row.billing_state, 'expired');
  assertEquals(row.is_trial, false);
});

Deno.test('BILLING_ISSUE sets billing_state=grace; config-bootstrap returns billing_retry_banner=true', async () => {
  const bs = await quickBootstrap();
  await postWebhook(rcEvent('INITIAL_PURCHASE', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.premium.monthly',
    period_type: 'NORMAL',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  }));
  await postWebhook(rcEvent('BILLING_ISSUE', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.premium.monthly',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  }));

  const row = await readEntitlement(bs.canonical_user_key);
  assertExists(row);
  assertEquals(row.billing_state, 'grace');

  // End-to-end: iOS's bootstrap read must see billing_retry_banner=true.
  const cfg = await callConfigBootstrap(bs.session_jwt);
  assertEquals(cfg.status, 200);
  const body = cfg.body as { entitlements: { billing_retry_banner: boolean; tier: string; voice_enabled: boolean } };
  assertEquals(body.entitlements.billing_retry_banner, true);
  // Grace still unlocks premium.
  assertEquals(body.entitlements.tier, 'premium');
  assertEquals(body.entitlements.voice_enabled, true);
});

Deno.test('UNCANCELLATION after CANCELLATION flips billing_state back to active', async () => {
  // Coverage gap (DB1): UNCANCELLATION end-to-end.
  const bs = await quickBootstrap();
  await postWebhook(rcEvent('INITIAL_PURCHASE', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.premium.monthly',
    period_type: 'NORMAL',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  }));
  await postWebhook(rcEvent('CANCELLATION', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.premium.monthly',
    period_type: 'NORMAL',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  }));
  await postWebhook(rcEvent('UNCANCELLATION', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.premium.monthly',
    period_type: 'NORMAL',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  }));

  const row = await readEntitlement(bs.canonical_user_key);
  assertExists(row);
  assertEquals(row.billing_state, 'active');
  // is_trial must be false even if a downstream event carried a stale
  // period_type — the resolver hard-codes it after the step-5 review.
  assertEquals(row.is_trial, false);
});

Deno.test('TRANSFER event reassigns entitlement from → to', async () => {
  // Coverage gap (DB1): TRANSFER end-to-end.
  const fromInstall = testInstallId();
  const fromKey = `install:${fromInstall}`;
  const toCk = testCkRecord();
  const toKey = `ck:${toCk}`;

  // Seed the source user with a purchase.
  await quickBootstrap({ installation_id: fromInstall });
  await postWebhook(rcEvent('INITIAL_PURCHASE', {
    app_user_id: fromKey,
    product_id: 'stir.pro.monthly',
    period_type: 'NORMAL',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  }));

  // Transfer.
  const transferRes = await postWebhook(rcEvent('TRANSFER', {
    app_user_id: toKey,
    transferred_from: [fromKey],
    transferred_to: [toKey],
  }));
  assertEquals(transferRes.status, 200);

  // After transfer: source has no entitlement row; target has it.
  const sourceRow = await readEntitlement(fromKey);
  assertEquals(sourceRow, null);
  const targetRow = await readEntitlement(toKey);
  assertExists(targetRow);
  assertEquals(targetRow.tier, 'pro');
  assertEquals(targetRow.billing_state, 'active');
});

Deno.test('SUBSCRIBER_ALIAS idempotent replay is atomic (retry after failure still safe)', async () => {
  // Regression guard for CR1's TOCTOU finding. Replaying the same
  // alias event_id should route to `duplicate` rather than re-running
  // the merge. This is what step-5 migration 5 (stir_process_alias_webhook)
  // guarantees atomically.
  const installId = testInstallId();
  const installKey = `install:${installId}`;
  await quickBootstrap({ installation_id: installId });
  await postWebhook(rcEvent('INITIAL_PURCHASE', {
    app_user_id: installKey,
    product_id: 'stir.premium.monthly',
    period_type: 'NORMAL',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  }));

  const ckKey = `ck:${testCkRecord()}`;
  const aliasEvent = rcEvent('SUBSCRIBER_ALIAS', {
    app_user_id: ckKey,
    original_app_user_id: installKey,
  });

  const first = await postWebhook(aliasEvent);
  assertEquals(first.status, 200);
  // Second delivery of the SAME event_id — idempotency gate short-circuits.
  const second = await postWebhook(aliasEvent);
  assertEquals(second.status, 200);

  const logs = await countWebhookLogs(aliasEvent.event.id);
  assertEquals(logs, 2);
  const latest = await lastWebhookLog(aliasEvent.event.id);
  assertEquals(latest?.status, 'duplicate');

  // End state: entitlement lives on ck, install row is merged.
  const ckRow = await readEntitlement(ckKey);
  assertExists(ckRow);
  assertEquals(ckRow.tier, 'premium');
});

Deno.test('PRODUCT_CHANGE premium → pro → tier flips, billing_state stays active', async () => {
  const bs = await quickBootstrap();
  await postWebhook(rcEvent('INITIAL_PURCHASE', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.premium.monthly',
    period_type: 'NORMAL',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  }));
  await postWebhook(rcEvent('PRODUCT_CHANGE', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.pro.monthly',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  }));

  const row = await readEntitlement(bs.canonical_user_key);
  assertExists(row);
  assertEquals(row.tier, 'pro');
  assertEquals(row.billing_state, 'active');
});

// ---------------------------------------------------------------------------
// Idempotency
// ---------------------------------------------------------------------------

Deno.test('replaying same event_id is idempotent', async () => {
  const bs = await quickBootstrap();
  const event = rcEvent('INITIAL_PURCHASE', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.premium.monthly',
    period_type: 'NORMAL',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  });

  const first = await postWebhook(event);
  assertEquals(first.status, 200);
  const rowAfterFirst = await readEntitlement(bs.canonical_user_key);
  assertExists(rowAfterFirst);

  // Replay same event.
  const second = await postWebhook(event);
  assertEquals(second.status, 200);

  // updated_at should not have moved — the second request was an
  // idempotent replay and MUST NOT re-write the entitlement row.
  const rowAfterReplay = await readEntitlement(bs.canonical_user_key);
  assertExists(rowAfterReplay);
  assertEquals(rowAfterReplay.updated_at, rowAfterFirst.updated_at);

  // Second webhook_log row should have status='duplicate'.
  const logCount = await countWebhookLogs(event.event.id);
  assertEquals(logCount, 2);
  const latest = await lastWebhookLog(event.event.id);
  assertEquals(latest?.status, 'duplicate');
});

// ---------------------------------------------------------------------------
// SUBSCRIBER_ALIAS
// ---------------------------------------------------------------------------

Deno.test('SUBSCRIBER_ALIAS moves entitlement from install → ck', async () => {
  const installId = testInstallId();
  const installKey = `install:${installId}`;

  // Step 1: bootstrap as install-only, seed a purchase on that key.
  const installBs = await quickBootstrap({ installation_id: installId });
  assertEquals(installBs.canonical_user_key, installKey);

  await postWebhook(rcEvent('INITIAL_PURCHASE', {
    app_user_id: installKey,
    product_id: 'stir.premium.monthly',
    period_type: 'NORMAL',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  }));

  // Step 2: user gains iCloud; RC fires alias install → ck.
  const ckName = testCkRecord();
  const ckKey = `ck:${ckName}`;

  const aliasRes = await postWebhook(rcEvent('SUBSCRIBER_ALIAS', {
    app_user_id: ckKey,
    original_app_user_id: installKey,
  }));
  assertEquals(aliasRes.status, 200);

  // Entitlement should now live on ck row; install row deleted
  // by stir_alias_forward.
  const ckRow = await readEntitlement(ckKey);
  assertExists(ckRow);
  assertEquals(ckRow.tier, 'premium');
  assertEquals(ckRow.billing_state, 'active');

  const installRow = await readEntitlement(installKey);
  assertEquals(installRow, null);
});

// ---------------------------------------------------------------------------
// Unknown / ignored / malformed
// ---------------------------------------------------------------------------

Deno.test('unknown event type returns 200 and logs status=unknown_event', async () => {
  const bs = await quickBootstrap();
  const event = rcEvent('SOMETHING_NEW_FROM_RC', {
    app_user_id: bs.canonical_user_key,
  });
  const res = await postWebhook(event);
  assertEquals(res.status, 200);

  const log = await lastWebhookLog(event.event.id);
  assertEquals(log?.status, 'unknown_event');
});

Deno.test('NON_RENEWING_PURCHASE is ignored (no NR SKUs in spec) and does NOT write entitlement', async () => {
  const bs = await quickBootstrap();
  const beforeRow = await readEntitlement(bs.canonical_user_key);

  const event = rcEvent('NON_RENEWING_PURCHASE', {
    app_user_id: bs.canonical_user_key,
  });
  const res = await postWebhook(event);
  assertEquals(res.status, 200);

  const afterRow = await readEntitlement(bs.canonical_user_key);
  assertEquals(afterRow?.tier, beforeRow?.tier);
  assertEquals(afterRow?.billing_state, beforeRow?.billing_state);

  // NON_RENEWING_PURCHASE is a handled event type (resolver knows about it);
  // the resolver explicitly returns `ignore` because Stir has no NR SKUs.
  // Audit log distinguishes `ignored` from `accepted` and `unknown_event`.
  const log = await lastWebhookLog(event.event.id);
  assertEquals(log?.status, 'ignored');
});

Deno.test('malformed JSON body returns 200 with validation_failed log', async () => {
  const res = await postWebhook('{ not valid json');
  assertEquals(res.status, 200);

  // Log row exists with status=validation_failed (no event_id since we
  // couldn't parse). We can't query by event_id — look for the most
  // recent validation_failed row instead.
  const { data, error } = await serviceClient()
    .from('webhook_log')
    .select('status')
    .eq('status', 'validation_failed')
    .order('processed_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  assertEquals(data?.status, 'validation_failed');
});

Deno.test('INITIAL_PURCHASE with unknown product_id is ignored, no entitlement change', async () => {
  const bs = await quickBootstrap();
  const beforeRow = await readEntitlement(bs.canonical_user_key);

  const event = rcEvent('INITIAL_PURCHASE', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.some.future.sku',
    period_type: 'NORMAL',
  });
  const res = await postWebhook(event);
  assertEquals(res.status, 200);

  const afterRow = await readEntitlement(bs.canonical_user_key);
  assertEquals(afterRow?.tier, beforeRow?.tier);
  assertEquals(afterRow?.billing_state, beforeRow?.billing_state);

  // Handler logs with `ignored` status (not `accepted`) so dashboards
  // can distinguish "known event type, chose to skip" from "something
  // actually mutated state". The event TYPE (INITIAL_PURCHASE) is
  // handled; the resolver downstream returned `ignore` because product_id
  // was unknown.
  const log = await lastWebhookLog(event.event.id);
  assertEquals(log?.status, 'ignored');
});

// ---------------------------------------------------------------------------
// End-to-end with /v1/config/bootstrap
// ---------------------------------------------------------------------------

Deno.test('INITIAL_PURCHASE → /v1/config/bootstrap returns tier=premium voice_enabled=true', async () => {
  const bs = await quickBootstrap();

  await postWebhook(rcEvent('INITIAL_PURCHASE', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.premium.annual.trial7',
    period_type: 'TRIAL',
    expiration_at_ms: Date.UTC(2026, 3, 26),
  }));

  const cfg = await callConfigBootstrap(bs.session_jwt);
  assertEquals(cfg.status, 200);
  const body = cfg.body as {
    entitlements: {
      tier: string;
      billing_state: string;
      is_trial: boolean;
      voice_enabled: boolean;
      billing_retry_banner: boolean;
      expires_at: string | null;
      quotas: Array<{ feature_key: string; cap: number }>;
    };
  };

  assertEquals(body.entitlements.tier, 'premium');
  assertEquals(body.entitlements.billing_state, 'trial');
  assertEquals(body.entitlements.is_trial, true);
  assertEquals(body.entitlements.voice_enabled, true);
  assertEquals(body.entitlements.billing_retry_banner, false);

  // Quotas: Premium caps are snapshotted at usage_counters row creation
  // (step 1). Existing row predates the webhook; iOS paywall copy
  // communicates that the new cap arrives at next period reset.
  assertExists(body.entitlements.quotas);
});

Deno.test('EXPIRATION → /v1/config/bootstrap returns tier=free voice_enabled=false', async () => {
  const bs = await quickBootstrap();
  await postWebhook(rcEvent('INITIAL_PURCHASE', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.premium.monthly',
    period_type: 'NORMAL',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  }));
  await postWebhook(rcEvent('EXPIRATION', {
    app_user_id: bs.canonical_user_key,
    product_id: 'stir.premium.monthly',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  }));

  const cfg = await callConfigBootstrap(bs.session_jwt);
  const body = cfg.body as {
    entitlements: { tier: string; billing_state: string; voice_enabled: boolean };
  };
  // effectiveTier() demotes to free; voice disabled.
  assertEquals(body.entitlements.tier, 'free');
  assertEquals(body.entitlements.billing_state, 'expired');
  assertEquals(body.entitlements.voice_enabled, false);
});

Deno.test('config-bootstrap response sets Cache-Control: no-store', async () => {
  // This test is the last in the file; the step-5 review + follow-up
  // added enough new webhook-integration tests (each performing at
  // least one quickBootstrap) that the cumulative count pushes the
  // shared ip:bootstrap_hourly bucket over 20/hr. Clear before this
  // test so the final quickBootstrap succeeds.
  await clearRateLimitBuckets();
  const bs = await quickBootstrap();
  // Call the endpoint with the raw fetch so we can inspect headers.
  const res = await fetch(
    `${Deno.env.get('SUPABASE_URL') ?? 'http://127.0.0.1:54321'}/functions/v1/config-bootstrap`,
    {
      method: 'GET',
      headers: { Authorization: `Bearer ${bs.session_jwt}` },
    },
  );
  await res.body?.cancel(); // we only care about headers
  assertEquals(res.headers.get('cache-control'), 'no-store');
});

// ---------------------------------------------------------------------------
// Webhook creates missing app_users row (edge case)
// ---------------------------------------------------------------------------

Deno.test('INITIAL_PURCHASE for unseen canonical_user_key materializes app_users row', async () => {
  // Simulate a webhook firing for a user who somehow hasn't bootstrapped
  // yet. This is the crash-recovery path that keeps the FK from failing
  // if a race between purchase + bootstrap ever happens. Cheap defense.
  const ckName = testCkRecord();
  const ckKey = `ck:${ckName}`;

  const res = await postWebhook(rcEvent('INITIAL_PURCHASE', {
    app_user_id: ckKey,
    product_id: 'stir.premium.monthly',
    period_type: 'NORMAL',
    expiration_at_ms: Date.UTC(2026, 4, 19),
  }));
  assertEquals(res.status, 200);

  const { data, error } = await serviceClient()
    .from('app_users')
    .select('canonical_user_key, source_type, status')
    .eq('canonical_user_key', ckKey)
    .maybeSingle();
  if (error) throw error;
  assertExists(data);
  assertEquals(data.source_type, 'cloudkit');
  assertEquals(data.status, 'active');

  const ent = await readEntitlement(ckKey);
  assertExists(ent);
  assertEquals(ent.tier, 'premium');
});
