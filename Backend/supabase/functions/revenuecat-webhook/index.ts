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
  isEventFresh,
  MAX_EVENT_AGE_MS,
  RevenueCatWebhookEnvelope,
  resolveEventAction,
  verifyAuthHeader,
} from '../_shared/revenuecat.ts';
import { ZodError } from 'zod';

const WEBHOOK_SECRET = Deno.env.get('REVENUECAT_WEBHOOK_SECRET');

/**
 * Minimum webhook secret length. Raised from 16 to 32 after the step-5
 * review: a 16-char random alphanumeric is ~96 bits of entropy, which is
 * fine, but a shared secret protecting entitlement state warrants a wider
 * margin. `openssl rand -hex 32` produces a 64-char hex string that's
 * trivially rotatable via `supabase secrets set`. The runtime check here
 * is a safety net; the operational contract is the rotation runbook.
 */
const WEBHOOK_SECRET_MIN_LENGTH = 32;

/**
 * Maximum raw-body size accepted. Real RC payloads are 2–5 KB; 64 KiB is
 * generous. Defends against post-auth body-exhaustion: attacker with the
 * secret could send a multi-MB payload that buffers fully through
 * `req.text()` → `JSON.parse` → Zod → JSONB write. Platform gateway cap
 * (~6 MiB) is the upstream backstop.
 */
const MAX_BODY_BYTES = 64 * 1024;

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
  | 'ignored'
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
  if (!WEBHOOK_SECRET || WEBHOOK_SECRET.length < WEBHOOK_SECRET_MIN_LENGTH) {
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
  // Accept either `Authorization: <secret>` or `Authorization: Bearer <secret>`.
  // RC's dashboard lets the operator enter any string; normalizing here
  // means dashboard config + server env var don't have to agree on prefix
  // (operational brittleness the step-5 review flagged).
  const providedRaw = req.headers.get('authorization');
  const provided = providedRaw?.startsWith('Bearer ')
    ? providedRaw.slice(7)
    : providedRaw;
  if (!verifyAuthHeader(provided, WEBHOOK_SECRET)) {
    log.warn('signature_invalid', { has_header: Boolean(providedRaw) });
    // DO NOT log to webhook_log here. Unauthenticated requests are
    // potentially hostile; logging their body would burn storage and
    // could leak attacker-chosen content into dashboards.
    return new Response(
      JSON.stringify({ error: 'unauthorized' }),
      { status: 401, headers: { 'content-type': 'application/json' } },
    );
  }

  // -----------------------------------------------------------------------
  // 2b. Content-Type + size cap (post-auth; defense in depth)
  // -----------------------------------------------------------------------
  const contentType = req.headers.get('content-type') ?? '';
  if (!contentType.toLowerCase().startsWith('application/json')) {
    log.warn('unsupported_media_type', { content_type: contentType });
    return new Response(
      JSON.stringify({ error: 'unsupported_media_type', expected: 'application/json' }),
      { status: 415, headers: { 'content-type': 'application/json' } },
    );
  }
  const contentLength = Number(req.headers.get('content-length') ?? '0');
  // Header is attacker-forgeable; we also re-check after reading. This
  // lets us reject early on honest oversized payloads without buffering.
  if (contentLength > MAX_BODY_BYTES) {
    log.warn('body_too_large_header', { content_length: contentLength, limit: MAX_BODY_BYTES });
    return new Response(
      JSON.stringify({ error: 'payload_too_large', limit_bytes: MAX_BODY_BYTES }),
      { status: 413, headers: { 'content-type': 'application/json' } },
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

  // Post-read size check: content-length is attacker-forgeable, so we
  // re-verify after actually buffering. An undersized content-length
  // followed by a massive body would still hit the gateway's own cap,
  // but this gives us app-layer defense.
  if (rawBody.length > MAX_BODY_BYTES) {
    log.warn('body_too_large_actual', { actual: rawBody.length, limit: MAX_BODY_BYTES });
    return new Response(
      JSON.stringify({ error: 'payload_too_large', limit_bytes: MAX_BODY_BYTES }),
      { status: 413, headers: { 'content-type': 'application/json' } },
    );
  }

  let parsedJson: unknown;
  try {
    parsedJson = JSON.parse(rawBody);
  } catch (err) {
    log.warn('json_parse_failed', { err: String(err) });
    // Deliberately DO NOT store raw attacker-chosen bytes. The Zod
    // `issues` payload in the logger + the `json_parse_failed` log line
    // carry enough for debugging; persisting raw body content into the
    // audit log risks log-injection / XSS in downstream dashboards that
    // render the JSONB without encoding.
    await writeWebhookLog(client, log, {
      event_id: null,
      event_type: null,
      canonical_user_key: null,
      status: 'validation_failed',
      raw_payload: { _reason: 'json_parse_failed', _body_length: rawBody.length },
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
    // Store only a size-bounded redacted summary on Zod failure. Full
    // parsedJson can be arbitrarily large — previous behavior ingested
    // the entire parsed structure into the audit log, which a secret-
    // holder could abuse to bloat the log.
    const payloadPreview = JSON.stringify(parsedJson).slice(0, 2048);
    await writeWebhookLog(client, log, {
      event_id: null,
      event_type: null,
      canonical_user_key: null,
      status: 'validation_failed',
      raw_payload: {
        _reason: 'envelope_validation_failed',
        _preview: payloadPreview,
        _preview_truncated: payloadPreview.length === 2048,
      },
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
  // 3b. Replay-window / freshness check
  // -----------------------------------------------------------------------
  // Defense-in-depth against secret compromise: even with a valid auth
  // header, a captured event from >10 minutes ago won't be re-applied.
  // RC's own retry window is much shorter than this; legitimate
  // deliveries never trigger it.
  if (!isEventFresh(event)) {
    userLog.warn('event_stale', {
      event_id: event.id,
      event_type: event.type,
      event_timestamp_ms: event.event_timestamp_ms,
      max_age_ms: MAX_EVENT_AGE_MS,
    });
    await writeWebhookLog(client, userLog, {
      event_id: event.id,
      event_type: event.type,
      canonical_user_key: event.app_user_id,
      status: 'validation_failed',
      raw_payload: {
        _reason: 'stale_event',
        event_timestamp_ms: event.event_timestamp_ms ?? null,
        max_age_ms: MAX_EVENT_AGE_MS,
      },
    });
    // 200 so RC doesn't retry-storm a legitimately-old event; the audit
    // log captures the reject for review.
    return new Response(
      JSON.stringify({ received: true, status: 'stale_event' }),
      { status: 200, headers: { 'content-type': 'application/json' } },
    );
  }

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
        // Atomic idempotency + alias-forward via stir_process_alias_webhook.
        // The prior implementation inserted processed_webhook_events from
        // JS land and then called stir_alias_forward separately — a
        // TOCTOU bug: if the merge RPC threw after the idempotency row was
        // written, RC would retry, the idempotency check would short-circuit
        // as `duplicate`, and the alias would be silently lost. Moving both
        // into a single plpgsql transaction eliminates the window.
        const { data: aliasData, error: aliasError } = await client.rpc(
          'stir_process_alias_webhook',
          {
            p_event_id: event.id,
            p_event_type: event.type,
            p_from: action.from,
            p_to: action.to,
            p_raw_payload: envelope,
          },
        );
        if (aliasError) throw aliasError;

        const result = (aliasData ?? {}) as { status?: string };
        if (result.status === 'duplicate') {
          status = 'duplicate';
          userLog.info('idempotent_replay_alias', { event_id: event.id });
        } else {
          status = 'alias_processed';
          userLog.info('alias_forwarded', {
            event_id: event.id,
            from: action.from,
            to: action.to,
            result: aliasData,
          });
        }
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
        // webhook_log rows. Failure here is non-fatal — log + still
        // return 200, accepting the tradeoff that an RC retry could
        // produce a duplicate audit entry rather than cause a retry
        // storm on a permanently-ignored event type.
        const { error: upsertErr } = await client
          .from('processed_webhook_events')
          .upsert(
            { event_id: event.id, event_type: event.type },
            { onConflict: 'event_id', ignoreDuplicates: true },
          );
        if (upsertErr) {
          userLog.warn('ignore_idempotency_upsert_failed', {
            event_id: event.id,
            err_message: upsertErr.message,
          });
        }
        // A handled event that the resolver explicitly ignored (e.g.
        // NON_RENEWING_PURCHASE, EXPIRATION on unknown product) is
        // semantically different from an unknown event type. Reflect
        // that in the audit log so dashboards can distinguish "we know
        // about this type and chose to skip" from "this came from
        // nowhere."
        status = isHandledType ? 'ignored' : 'unknown_event';
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

// NOTE: `ensureAppUserRow` was removed in the step-5 review.
// - `upsert_entitlement` path: `stir_process_webhook_event` RPC ensures
//   app_users internally.
// - `alias` path: `stir_process_alias_webhook` RPC (migration 5) ensures
//   both rows internally.
// - `transfer` path: `stir_transfer_entitlement` RPC ensures the target.
// - `ignore` path: no DB row materialization needed.
//
// All ensure-app-user writes now live inside the RPC transaction that
// needs them, removing the TOCTOU window where the handler crashed
// between materialization and RPC execution.
