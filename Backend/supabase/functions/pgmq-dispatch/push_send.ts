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
  log: { info: (msg: string, fields?: Record<string, unknown>) => void },
  sender: APNsSender = sendAPNsPush,
): Promise<void> {
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
    await client
      .from('notification_jobs')
      .update({
        state: 'completed',
        processed_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
      .eq('id', job.id);
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
    await client
      .from('notification_jobs')
      .update({
        state: 'completed',
        processed_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
        error_message: `apns rejected token: ${result.apnsReason ?? 'BadDeviceToken'}`,
      })
      .eq('id', job.id);
    await client
      .from('device_installations')
      .update({ push_token: null, notifications_enabled: false })
      .eq('push_token', payload.apns_token);
    return;
  }

  // Other failures re-throw; outer loop schedules retry with backoff.
  throw new Error(
    `APNs push failed (reason=${result.reason}, status=${result.status}, apns=${
      result.apnsReason ?? 'n/a'
    })`,
  );
}
