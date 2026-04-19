// POST /functions/v1/revenuecat-webhook
// Logical endpoint: POST /v1/revenuecat/webhook (CLAUDE.md §endpoints).
//
// Receives RevenueCat webhook deliveries and updates entitlement_snapshots.
// Auth: shared-secret `Authorization` header verified against
// REVENUECAT_WEBHOOK_SECRET (constant-time compare).
//
// Flow:
//   1. Method check (405 on non-POST).
//   2. Authorization header verify — FIRST, before body parse. Failure → 401
//      logged at `warn`. No body, no webhook_log row (unauthenticated
//      requests could be hostile; we don't want to burn log volume on them).
//   3. Read raw body string, parse JSON, Zod-validate envelope.
//      Failure → 200 { received: true, status: "<reason>" } so RC doesn't
//      retry a permanently malformed payload, plus a webhook_log row at
//      `error` severity so Sentry can surface the bug.
//   4. Resolve action from event (pure; see _shared/revenuecat.ts).
//   5. Apply action:
//      - upsert_entitlement → stir_process_webhook_event RPC (atomic
//        idempotency + upsert).
//      - alias              → stir_alias_forward RPC (full identity merge).
//      - transfer           → stir_transfer_entitlement RPC.
//      - ignore             → no-op, log only.
//   6. webhook_log row with final status.
//   7. Return 200 { received: true }.
//
// Return-200-on-nearly-everything is deliberate: RC retries on non-2xx
// with backoff up to several days. Our own defensive bugs (malformed
// payloads, auth header typos) should not generate retry storms on RC's
// side. Only signature verify (a real security boundary) returns 401.

import { createLogger, requestIdFrom } from '../_shared/logger.ts';
import { createServiceClient } from '../_shared/db.ts';
import {
  HANDLED_EVENT_TYPES,
  RevenueCatWebhookEnvelope,
  resolveEventAction,
  verifyAuthHeader,
} from '../_shared/revenuecat.ts';
import { ZodError } from 'zod';

const WEBHOOK_SECRET = Deno.env.get('REVENUECAT_WEBHOOK_SECRET');

/**
 * webhook_log.status values. Keep in sync with the column COMMENT in
 * migration 20260419000002_init_webhook_log.sql.
 */
type WebhookLogStatus =
  | 'accepted'
  | 'duplicate'
  | 'signature_invalid'
  | 'validation_failed'
  | 'unknown_event'
  | 'alias_processed'
  | 'transfer_processed'
  | 'error';

interface WebhookLogInsert {
  event_id: string | null;
  event_type: string | null;
  canonical_user_key: string | null;
  status: WebhookLogStatus;
  raw_payload: unknown;
}

Deno.serve(async (req) => {
  const requestId = requestIdFrom(req);
  const endpoint = '/v1/revenuecat/webhook';
  const log = await createLogger(requestId, endpoint);

  // -----------------------------------------------------------------------
  // 0. Environment sanity
  // -----------------------------------------------------------------------
  if (!WEBHOOK_SECRET || WEBHOOK_SECRET.length < 16) {
    // Misconfigured environment. Fail loudly rather than accept any
    // request. 500 (not 401) so RC retries if we accidentally ship without
    // the secret set — they'll keep delivering while we fix it.
    log.error('webhook_secret_missing_or_short');
    return new Response(
      JSON.stringify({ error: 'webhook_secret_unconfigured' }),
      { status: 500, headers: { 'content-type': 'application/json' } },
    );
  }

  // -----------------------------------------------------------------------
  // 1. Method
  // -----------------------------------------------------------------------
  if (req.method !== 'POST') {
    log.warn('method_not_allowed', { method: req.method });
    return new Response(
      JSON.stringify({ error: 'method_not_allowed', allowed: ['POST'] }),
      { status: 405, headers: { 'content-type': 'application/json', allow: 'POST' } },
    );
  }

  // -----------------------------------------------------------------------
  // 2. Authorization header verify
  // -----------------------------------------------------------------------
  const provided = req.headers.get('authorization');
  if (!verifyAuthHeader(provided, WEBHOOK_SECRET)) {
    log.warn('signature_invalid', { has_header: Boolean(provided) });
    // DO NOT log to webhook_log here. Unauthenticated requests are
    // potentially hostile; logging their body would burn storage and
    // could leak attacker-chosen content into dashboards.
    return new Response(
      JSON.stringify({ error: 'unauthorized' }),
      { status: 401, headers: { 'content-type': 'application/json' } },
    );
  }

  // -----------------------------------------------------------------------
  // 3. Parse + validate envelope
  // -----------------------------------------------------------------------
  const started = performance.now();
  const client = createServiceClient();

  let rawBody: string;
  try {
    rawBody = await req.text();
  } catch (err) {
    log.error('body_read_failed', err);
    return new Response(
      JSON.stringify({ received: true, status: 'validation_failed' }),
      { status: 200, headers: { 'content-type': 'application/json' } },
    );
  }

  let parsedJson: unknown;
  try {
    parsedJson = JSON.parse(rawBody);
  } catch (err) {
    log.warn('json_parse_failed', { err: String(err) });
    await writeWebhookLog(client, log, {
      event_id: null,
      event_type: null,
      canonical_user_key: null,
      status: 'validation_failed',
      raw_payload: { _raw_body: rawBody.slice(0, 2048) }, // cap
    });
    return new Response(
      JSON.stringify({ received: true, status: 'validation_failed' }),
      { status: 200, headers: { 'content-type': 'application/json' } },
    );
  }

  let envelope;
  try {
    envelope = RevenueCatWebhookEnvelope.parse(parsedJson);
  } catch (err) {
    if (err instanceof ZodError) {
      log.error(
        'envelope_validation_failed',
        err,
        { issues: err.issues.slice(0, 5) },
      );
    } else {
      log.error('envelope_validation_error', err);
    }
    await writeWebhookLog(client, log, {
      event_id: null,
      event_type: null,
      canonical_user_key: null,
      status: 'validation_failed',
      raw_payload: parsedJson,
    });
    return new Response(
      JSON.stringify({ received: true, status: 'validation_failed' }),
      { status: 200, headers: { 'content-type': 'application/json' } },
    );
  }

  const event = envelope.event;
  const userLog = await createLogger(requestId, endpoint, event.app_user_id);
  userLog.info('webhook_received', {
    event_id: event.id,
    event_type: event.type,
    environment: event.environment,
    product_id: event.product_id,
  });

  // -----------------------------------------------------------------------
  // 4. Resolve action from event
  // -----------------------------------------------------------------------
  const action = resolveEventAction(event);
  const isHandledType = HANDLED_EVENT_TYPES.has(event.type);

  // -----------------------------------------------------------------------
  // 5. Apply action
  // -----------------------------------------------------------------------
  let status: WebhookLogStatus;
  let canonicalUserKey: string | null = event.app_user_id;

  try {
    switch (action.kind) {
      case 'upsert_entitlement': {
        canonicalUserKey = action.canonical_user_key;
        const { data, error } = await client.rpc('stir_process_webhook_event', {
          p_event_id: event.id,
          p_event_type: event.type,
          p_canonical_user_key: action.canonical_user_key,
          p_tier: action.tier,
          p_billing_state: action.billing_state,
          p_is_trial: action.is_trial,
          p_expires_at: action.expires_at,
          p_raw_payload: envelope,
        });
        if (error) throw error;

        const result = (data ?? {}) as { status?: string; app_user_created?: boolean };
        if (result.status === 'duplicate') {
          status = 'duplicate';
          userLog.info('idempotent_replay', { event_id: event.id });
        } else {
          status = 'accepted';
          userLog.info('entitlement_upserted', {
            event_id: event.id,
            tier: action.tier,
            billing_state: action.billing_state,
            is_trial: action.is_trial,
            expires_at: action.expires_at,
            app_user_created: Boolean(result.app_user_created),
          });
        }
        break;
      }

      case 'alias': {
        canonicalUserKey = action.to;
        // Idempotency: if the event_id was already processed, short-circuit.
        const dupCheck = await client
          .from('processed_webhook_events')
          .insert({ event_id: event.id, event_type: event.type })
          .select('event_id');

        if (dupCheck.error) {
          // 23505 = unique violation → duplicate event.
          const pgCode = (dupCheck.error as { code?: string }).code;
          if (pgCode === '23505') {
            status = 'duplicate';
            userLog.info('idempotent_replay_alias', { event_id: event.id });
            break;
          }
          throw dupCheck.error;
        }

        // Ensure both from + to rows exist in app_users. stir_alias_forward
        // requires this — from:exist, to:exist. If RC sends an alias for
        // an install:<uuid> we've never seen, we materialize a row for it
        // so the merge has something to move.
        await ensureAppUserRow(client, action.from);
        await ensureAppUserRow(client, action.to);

        const { data: aliasData, error: aliasError } = await client.rpc(
          'stir_alias_forward',
          {
            p_install_key: action.from,
            p_ck_key: action.to,
          },
        );
        if (aliasError) throw aliasError;
        userLog.info('alias_forwarded', {
          event_id: event.id,
          from: action.from,
          to: action.to,
          result: aliasData,
        });
        status = 'alias_processed';
        break;
      }

      case 'transfer': {
        canonicalUserKey = action.to;
        userLog.warn('transfer_event', {
          event_id: event.id,
          from: action.from,
          to: action.to,
        });
        const { error: transferError } = await client.rpc(
          'stir_transfer_entitlement',
          {
            p_event_id: event.id,
            p_event_type: event.type,
            p_from: action.from,
            p_to: action.to,
            p_raw_payload: envelope,
          },
        );
        if (transferError) throw transferError;
        status = 'transfer_processed';
        break;
      }

      case 'ignore': {
        // Record the event_id in processed_webhook_events so a retry
        // of the same ignore-path event doesn't generate duplicate
        // webhook_log rows. Use upsert so we don't fail on duplicates.
        await client
          .from('processed_webhook_events')
          .upsert(
            { event_id: event.id, event_type: event.type },
            { onConflict: 'event_id', ignoreDuplicates: true },
          );
        status = isHandledType ? 'accepted' : 'unknown_event';
        userLog.info(isHandledType ? 'event_ignored' : 'unknown_event_type', {
          event_id: event.id,
          event_type: event.type,
          reason: action.reason,
        });
        break;
      }
    }
  } catch (err) {
    userLog.error('webhook_processing_error', err, {
      event_id: event.id,
      event_type: event.type,
    });
    await writeWebhookLog(client, userLog, {
      event_id: event.id,
      event_type: event.type,
      canonical_user_key: canonicalUserKey,
      status: 'error',
      raw_payload: envelope,
    });
    // Return 500 so RC retries — this is a server-side problem we want
    // to recover from. All the known-bad paths above are handled at 200.
    return new Response(
      JSON.stringify({ error: 'internal_error' }),
      { status: 500, headers: { 'content-type': 'application/json' } },
    );
  }

  // -----------------------------------------------------------------------
  // 6. webhook_log
  // -----------------------------------------------------------------------
  await writeWebhookLog(client, userLog, {
    event_id: event.id,
    event_type: event.type,
    canonical_user_key: canonicalUserKey,
    status,
    raw_payload: envelope,
  });

  userLog.info('request_complete', {
    event_id: event.id,
    event_type: event.type,
    status,
    latency_ms: Math.round(performance.now() - started),
  });

  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  });
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function writeWebhookLog(
  client: ReturnType<typeof createServiceClient>,
  log: { warn: (msg: string, meta?: Record<string, unknown>) => void },
  row: WebhookLogInsert,
): Promise<void> {
  const { error } = await client.from('webhook_log').insert(row);
  if (error) {
    // Log failure is bad but NOT request-failing. RC doesn't care whether
    // we audit — they care whether we 2xx'd.
    log.warn('webhook_log_write_failed', {
      err_message: error.message,
      status: row.status,
      event_id: row.event_id,
    });
  }
}

/**
 * Materialize an `app_users` row for a canonical_user_key that doesn't yet
 * exist. Used by SUBSCRIBER_ALIAS when RC's original_app_user_id refers to
 * an install key the server never bootstrapped — happens if a user
 * purchases mid-state-change or during RC dashboard test events.
 */
async function ensureAppUserRow(
  client: ReturnType<typeof createServiceClient>,
  canonicalKey: string,
): Promise<void> {
  const source = canonicalKey.startsWith('ck:') ? 'cloudkit' : 'install';
  const { error } = await client
    .from('app_users')
    .upsert(
      {
        canonical_user_key: canonicalKey,
        source_type: source,
        revenuecat_app_user_id: canonicalKey,
        status: 'active',
      },
      { onConflict: 'canonical_user_key', ignoreDuplicates: true },
    );
  if (error) throw error;
}
