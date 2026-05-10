// SCA-115 — extracted from pgmq-dispatch/index.ts so processPushSend is
// importable by integration tests without triggering `Deno.serve()` at
// module load. The runtime entry (`index.ts`) re-exports from here so
// the deployed function still has a single import surface.
//
// Behavior is unchanged from the inline implementation. The only seam
// added is the optional `sender` parameter on `processPushSend` so a
// test can swap `sendAPNsPush` directly. In production `index.ts`
// always passes the real `sendAPNsPush`.

import { z } from 'zod';
import type { createServiceClient } from '../_shared/db.ts';
import { type APNsPushInput, type APNsPushResult, sendAPNsPush } from '../_shared/apns.ts';

// W24 (SA1 W3): runtime shape validation of push_send payload. Pre-fix
// the handler used `as PushSendPayload` + presence check only — an errant
// writer inserting a malformed payload would get no signal until APNs
// rejected the malformed HTTP/2 request. Explicit Zod validation at the
// boundary keeps the trust boundary explicit: `notification_jobs` is
// service-role-only today, but one errant service caller (manual psql,
// future recipe-import regression, etc.) can't cause CRLF-injection in
// apns-collapse-id or misroute production pushes to sandbox.
export const PushSendPayloadSchema = z.object({
  template: z.enum(['reactivation', 'import_completion', 'cook_reminder', 'billing_grace']),
  title: z.string().min(1).max(256),
  body: z.string().min(1).max(2048),
  deep_link: z.string().regex(/^stir:\/\//).max(512).optional(),
  apns_token: z.string().regex(/^[0-9a-fA-F]{64}$/),
  environment: z.enum(['production', 'sandbox']),
}).strict();

export type PushSendPayload = z.infer<typeof PushSendPayloadSchema>;

// SCA-296 C1: narrow a nullable apns_environment (the schema lets
// device_installations.apns_environment be NULL — the CHECK only
// constrains non-null values) to the z.enum the downstream
// PushSendPayloadSchema accepts. Returns null if the raw value isn't a
// valid APNs environment so callers can skip enqueue + log a typed
// warning instead of poisoning notification_jobs with a row that burns
// MAX_ATTEMPTS retries before dead-lettering.
//
// Lives here (not _shared/) for two reasons: (a) it's the natural
// neighbor of PushSendPayloadSchema.environment whose enum it mirrors;
// (b) push_send.ts has no top-level Deno.serve, so tests can import it
// without spinning a server. The revenuecat-webhook billing_grace
// enqueue (revenuecat-webhook/index.ts:687,701) has the same shape
// and should pick up this guard the next time it's touched (SCA-296
// scope is pgmq-dispatch only).
export function validatePushEnvironment(
  raw: string | null | undefined,
): 'production' | 'sandbox' | null {
  return raw === 'production' || raw === 'sandbox' ? raw : null;
}

export interface PushSendJob {
  id: string;
  canonical_user_key: string;
  kind: 'recipe_import_async' | 'push_send';
  state: 'pending' | 'processing' | 'completed' | 'failed';
  attempt_count: number;
  payload_json: unknown;
}

/** Pluggable APNs sender — defaults to the real sendAPNsPush. Tests pass
 *  a mock that scripts response codes per scenario. */
export type APNsSender = (input: APNsPushInput) => Promise<APNsPushResult>;

/**
 * push_send job processor (step 8 — reactivation + import_completion +
 * cook_reminder + billing_grace pushes).
 *
 * Failure classification:
 *   - bad_device_token / unregistered → mark job COMPLETED (token is dead,
 *     not our bug); null out the token on device_installations so future
 *     enqueues skip it.
 *   - rate_limited / server_error    → THROW, lets the outer try/catch
 *     schedule a retry with backoff.
 *   - config_invalid / missing_secret → THROW and page; means our APNs
 *     signing config is wrong, not a per-device issue.
 */
export async function processPushSend(
  client: ReturnType<typeof createServiceClient>,
  job: PushSendJob,
  log: {
    info: (msg: string, fields?: Record<string, unknown>) => void;
    // SCA-296 C2: warn severity for swallowed DB UPDATE errors. Optional
    // so the existing test's quietLogger (info-only stub) keeps compiling;
    // production createLogger always supplies warn. Fall back to info
    // when absent so the line still lands somewhere.
    warn?: (msg: string, fields?: Record<string, unknown>) => void;
  },
  sender: APNsSender = sendAPNsPush,
): Promise<void> {
  // Single warn shim so the call sites below don't repeat the fallback.
  const logWarn = log.warn ?? log.info;
  const parsed = PushSendPayloadSchema.safeParse(job.payload_json);
  if (!parsed.success) {
    throw new Error(
      `invalid push_send payload: ${
        parsed.error.errors.map((e) => `${e.path.join('.')}=${e.message}`).join(', ')
      }`,
    );
  }
  const payload: PushSendPayload = parsed.data;

  const result = await sender({
    token: payload.apns_token,
    environment: payload.environment,
    category: payload.template,
    alert: { title: payload.title, body: payload.body },
    ...(payload.deep_link ? { data: { deep_link: payload.deep_link } } : {}),
  });

  if (result.ok) {
    log.info('push_sent', {
      job_id: job.id,
      template: payload.template,
      apns_id: result.apnsId,
    });
    // SCA-296 C2: error must not be silently swallowed. If the row UPDATE
    // fails after a successful APNs send the reclaim sweep will re-claim
    // 'processing' and APNs gets a duplicate delivery. Match the
    // index.ts:464-469 pattern (job_mark_complete_failed warning, retry
    // path owns recovery). We don't re-throw here: APNs has already
    // accepted the push, the outer loop's retry would issue a SECOND
    // delivery — strictly worse than tolerating one duplicate from the
    // reclaim sweep on the rare case the warning fires.
    const { error: markErr } = await client
      .from('notification_jobs')
      .update({
        state: 'completed',
        processed_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
      .eq('id', job.id);
    if (markErr) {
      logWarn('job_mark_complete_failed', {
        job_id: job.id,
        branch: 'push_sent',
        err: String(markErr),
      });
    }
    return;
  }

  // Failure path.
  if (result.reason === 'bad_device_token') {
    // Dead token — complete the job and null out device_installations.push_token
    // so future reactivation/import-completion enqueues skip this device.
    log.info('push_token_dead', {
      job_id: job.id,
      status: result.status,
      apns_reason: result.apnsReason,
    });
    // SCA-296 C2: if either UPDATE fails we re-throw so the outer retry
    // loop catches it. APNs has rejected the token, so a retry's
    // sendAPNsPush will get the same bad_device_token reason and the
    // second pass will null the token again — idempotent. Orphaning the
    // row in 'processing' is strictly worse (reclaim sweep duplicates
    // a no-op fetch to APNs; healthy tokens with the same string never
    // get nulled).
    const { error: jobUpdErr } = await client
      .from('notification_jobs')
      .update({
        state: 'completed',
        processed_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        error_message: `apns rejected token: ${result.apnsReason ?? 'BadDeviceToken'}`,
      })
      .eq('id', job.id);
    if (jobUpdErr) {
      logWarn('job_mark_complete_failed', {
        job_id: job.id,
        branch: 'bad_device_token',
        err: String(jobUpdErr),
      });
      throw new Error(`notification_jobs UPDATE failed: ${jobUpdErr.message ?? String(jobUpdErr)}`);
    }
    const { error: installUpdErr } = await client
      .from('device_installations')
      .update({ push_token: null, notifications_enabled: false })
      .eq('push_token', payload.apns_token);
    if (installUpdErr) {
      logWarn('device_install_null_failed', {
        job_id: job.id,
        err: String(installUpdErr),
      });
      throw new Error(
        `device_installations null UPDATE failed: ${installUpdErr.message ?? String(installUpdErr)}`,
      );
    }
    return;
  }

  // Other failures re-throw; outer loop schedules retry with backoff.
  throw new Error(
    `APNs push failed (reason=${result.reason}, status=${result.status}, apns=${
      result.apnsReason ?? 'n/a'
    })`,
  );
}
