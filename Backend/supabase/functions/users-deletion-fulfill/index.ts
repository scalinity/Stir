// POST /functions/v1/users-deletion-fulfill
// Invoked by pg_cron every 5 minutes (and ops manual trigger via
// public.stir_deletion_fulfill_trigger_once()).
//
// Walks rows in deletion_requests where state='approved', flips each to
// 'processing', then runs subsystem cleanup steps in order:
//
//   1. PostHog identify-merge — emit $delete_person capture so the
//      retention pipeline marks the distinct_id for cleanup.
//   2. Sentry user erase — DELETE the user identifier from Sentry's user
//      feedback / event metadata. Best-effort; SENTRY_AUTH_TOKEN env var
//      gate.
//   3. RevenueCat alias cleanup — DELETE /v1/subscribers/{app_user_id}.
//      Best-effort; REVENUECAT_SECRET_API_KEY env var gate.
//   4. CloudKit zone-delete trigger — Apple's CloudKit Web Services API
//      cannot reach a user's PRIVATE database from server-side. We mark
//      external_refs_json.cloudkit.requires_client_action=true; iOS sees
//      the marker on next launch and triggers CKContainer.privateCloudDatabase
//      .deleteRecordZone(zoneID). Until the user re-launches, their CloudKit
//      data persists — Privacy Policy §6 acknowledges this.
//   5. Postgres row sweep — LAST step. Insert audit_log durable record,
//      THEN DELETE FROM app_users (CASCADE-deletes device_installations,
//      entitlement_snapshots, usage_counters, ai_request_log,
//      notification_jobs, AND deletion_requests itself). The audit_log
//      row is the surviving anchor.
//
// State transitions: approved -> processing -> completed | failed.
// Resume policy: if a previous tick partially succeeded, the
// external_refs_json marker tells us which subsystems to skip on retry.
// Failed rows require ops replay back to 'approved' after triage; the
// next tick resumes from the preserved external_refs_json.
//
// Auth: shared X-Stir-Cron-Secret header gate (same as pgmq-dispatch).
// Production MUST set STIR_PGMQ_DISPATCH_SECRET; in dev/local without
// the secret, the gate degrades to a once-per-isolate warn and accepts
// the call.
//
// SCA-88. Pairs with docs/runbooks/deletion-request-fulfillment.md and
// docs/decisions/0031-deletion-fulfillment-ordering.md.

import { z } from 'zod';
import { createServiceClient } from '../_shared/db.ts';
import { createLogger, requestIdFrom } from '../_shared/logger.ts';
import { ErrorCode, jsonError, jsonOk } from '../_shared/errors.ts';
import { capturePosthogEvent } from '../_shared/posthog.ts';
import type { Logger } from '../_shared/logger.ts';

const CLAIM_LIMIT = 5; // one tick handles at most 5 deletions
const FAILURE_REASON_MAX = 1024;

// ---- Auth ----

const SHARED_SECRET = Deno.env.get('STIR_PGMQ_DISPATCH_SECRET');
let unsetSecretWarned = false;

function authorize(req: Request): { ok: true } | { ok: false; reason: string } {
  if (!SHARED_SECRET) {
    if (!unsetSecretWarned) {
      console.warn(
        '[users-deletion-fulfill] STIR_PGMQ_DISPATCH_SECRET not set; auth gate degraded (dev/local). Set via supabase secrets set in production.',
      );
      unsetSecretWarned = true;
    }
    return { ok: true };
  }
  const incoming = req.headers.get('X-Stir-Cron-Secret') ?? '';
  // Constant-time compare.
  const a = new TextEncoder().encode(incoming);
  const b = new TextEncoder().encode(SHARED_SECRET);
  if (a.byteLength !== b.byteLength) return { ok: false, reason: 'secret_length_mismatch' };
  let mismatch = 0;
  for (let i = 0; i < a.byteLength; i++) mismatch |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return mismatch === 0 ? { ok: true } : { ok: false, reason: 'secret_mismatch' };
}

// ---- Subsystem result shape ----

type SubsystemKey = 'posthog' | 'sentry' | 'revenuecat' | 'cloudkit' | 'postgres';

interface SubsystemRecord {
  // ISO timestamp on success.
  completed_at?: string;
  // Set when the subsystem chose not to act because a server-side action
  // is impossible (CloudKit) or a secret is absent (best-effort skip).
  requires_manual_action?: boolean;
  // Error string on failure (truncated).
  error?: string;
  // Subsystem-specific opaque data (distinct_id_hash, app_user_id_hash, ...).
  [key: string]: unknown;
}

type ExternalRefs = Partial<Record<SubsystemKey, SubsystemRecord>>;

// ---- Subsystems ----

interface FulfillContext {
  rowId: string;
  canonicalUserKey: string;
  canonicalUserKeyHash: string;
  refs: ExternalRefs;
  log: Logger;
}

async function stepPostHog(ctx: FulfillContext): Promise<SubsystemRecord> {
  // PostHog has no API to delete a person from an Edge Function with the
  // public ingest key. We emit a `$delete_person` capture event which
  // PostHog routes to the retention pipeline. Best-effort.
  if (ctx.refs.posthog?.completed_at) return ctx.refs.posthog;

  try {
    capturePosthogEvent(ctx.log, {
      event: '$delete_person',
      distinctId: ctx.canonicalUserKeyHash,
      properties: {
        deletion_request_id: ctx.rowId,
        source: 'users-deletion-fulfill',
      },
    });
    return {
      completed_at: new Date().toISOString(),
      distinct_id_hash: ctx.canonicalUserKeyHash,
    };
  } catch (err) {
    return { error: truncate(String(err), 200) };
  }
}

async function stepSentry(ctx: FulfillContext): Promise<SubsystemRecord> {
  if (ctx.refs.sentry?.completed_at) return ctx.refs.sentry;

  // Sentry's user-erase API requires SENTRY_AUTH_TOKEN with project:write
  // scope. If not configured, mark for manual action and continue —
  // privacy promise is best-effort for analytics platforms.
  const token = Deno.env.get('SENTRY_AUTH_TOKEN');
  const orgSlug = Deno.env.get('SENTRY_ORG_SLUG');
  const projectSlug = Deno.env.get('SENTRY_PROJECT_SLUG');
  if (!token || !orgSlug || !projectSlug) {
    return {
      requires_manual_action: true,
      error: 'sentry_auth_token_or_slugs_unset',
    };
  }

  try {
    // Sentry's "delete user feedback" by hash:
    //   POST /api/0/projects/{org}/{project}/user-feedback/?user.id={hash}
    // Erase event metadata containing the user hash via the data-scrubbing
    // settings already in place (this is workspace-level config). Here we
    // submit a one-off issue-deletion request scoped to user_hash.
    const url = `https://sentry.io/api/0/projects/${orgSlug}/${projectSlug}/issues/?query=user.id:${ctx.canonicalUserKeyHash}`;
    const resp = await fetch(url, {
      method: 'DELETE',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
    });
    if (!resp.ok && resp.status !== 404) {
      return { error: truncate(`sentry_http_${resp.status}`, 200) };
    }
    return {
      completed_at: new Date().toISOString(),
      user_id_hash: ctx.canonicalUserKeyHash,
    };
  } catch (err) {
    return { error: truncate(String(err), 200) };
  }
}

async function stepRevenueCat(ctx: FulfillContext): Promise<SubsystemRecord> {
  if (ctx.refs.revenuecat?.completed_at) return ctx.refs.revenuecat;

  const token = Deno.env.get('REVENUECAT_SECRET_API_KEY');
  if (!token) {
    return {
      requires_manual_action: true,
      error: 'revenuecat_secret_api_key_unset',
    };
  }

  // RevenueCat's app_user_id is the canonical_user_key (RC alias-forward
  // tracks every prior install id under the same canonical row).
  // DELETE /v1/subscribers/{app_user_id} hard-deletes the subscriber.
  try {
    const url = `https://api.revenuecat.com/v1/subscribers/${
      encodeURIComponent(ctx.canonicalUserKey)
    }`;
    const resp = await fetch(url, {
      method: 'DELETE',
      headers: {
        Authorization: `Bearer ${token}`,
      },
    });
    if (!resp.ok && resp.status !== 404) {
      return { error: truncate(`revenuecat_http_${resp.status}`, 200) };
    }
    return {
      completed_at: new Date().toISOString(),
      app_user_id_hash: ctx.canonicalUserKeyHash,
    };
  } catch (err) {
    return { error: truncate(String(err), 200) };
  }
}

async function stepCloudKit(ctx: FulfillContext): Promise<SubsystemRecord> {
  // Server-side CloudKit zone-delete is not possible: Apple's Web Services
  // API only addresses the public DB. Private DB lives on the user's
  // iCloud and is reachable only by code running in their app process.
  //
  // Mark requires_client_action=true. iOS reads this field on next launch
  // (via /v1/session/bootstrap or a dedicated /v1/users/deletion-status
  // probe) and triggers CKContainer.privateCloudDatabase.deleteRecordZone.
  // Until the user re-launches, their CloudKit data persists — Privacy
  // Policy §6 documents this asymmetry.
  if (ctx.refs.cloudkit?.completed_at || ctx.refs.cloudkit?.requires_client_action) {
    return ctx.refs.cloudkit;
  }
  return {
    requires_client_action: true,
    triggered_at: new Date().toISOString(),
  };
}

async function stepPostgres(
  ctx: FulfillContext,
  client: ReturnType<typeof createServiceClient>,
): Promise<SubsystemRecord> {
  if (ctx.refs.postgres?.completed_at) return ctx.refs.postgres;

  // Insert durable audit_log row BEFORE deleting app_users. The deletion
  // CASCADEs to deletion_requests itself (FK reference), so the audit
  // anchor needs to live on a different table.
  const { error: auditErr } = await client.from('audit_log').insert({
    actor_id: null, // system automation
    actor_email: null,
    action: 'deletion_requests.fulfilled',
    target_table: 'app_users',
    target_id: ctx.canonicalUserKeyHash,
    before_json: { canonical_user_key_hash: ctx.canonicalUserKeyHash },
    after_json: {
      deletion_request_id: ctx.rowId,
      external_refs: ctx.refs,
    },
  });
  if (auditErr) {
    return { error: truncate(`audit_log_insert_failed: ${auditErr.message}`, 200) };
  }

  // Now the irreversible step. ON DELETE CASCADE fans out across:
  //   device_installations, entitlement_snapshots, usage_counters,
  //   ai_request_log, notification_jobs, deletion_requests.
  const { error: delErr } = await client
    .from('app_users')
    .delete()
    .eq('canonical_user_key', ctx.canonicalUserKey);
  if (delErr) {
    return { error: truncate(`app_users_delete_failed: ${delErr.message}`, 200) };
  }
  return {
    completed_at: new Date().toISOString(),
    canonical_user_key_hash: ctx.canonicalUserKeyHash,
  };
}

// ---- Main worker ----

interface WorkerSummary {
  claimed: number;
  completed: number;
  failed: number;
  partial: number;
}

async function processOne(
  client: ReturnType<typeof createServiceClient>,
  row: {
    id: string;
    canonical_user_key: string;
    canonical_user_key_hash: string;
    external_refs_json: ExternalRefs;
  },
  log: Logger,
): Promise<'completed' | 'partial' | 'failed'> {
  const ctx: FulfillContext = {
    rowId: row.id,
    canonicalUserKey: row.canonical_user_key,
    canonicalUserKeyHash: row.canonical_user_key_hash,
    refs: row.external_refs_json ?? {},
    log,
  };

  // Run subsystems in order. Each writes its result into ctx.refs.
  ctx.refs.posthog = await stepPostHog(ctx);
  ctx.refs.sentry = await stepSentry(ctx);
  ctx.refs.revenuecat = await stepRevenueCat(ctx);
  ctx.refs.cloudkit = await stepCloudKit(ctx);

  // Persist external_refs_json BEFORE running the postgres sweep — the
  // sweep cascade-deletes deletion_requests itself, so this is the last
  // chance to record the upstream subsystem state on the row.
  await client
    .from('deletion_requests')
    .update({ external_refs_json: ctx.refs as Record<string, unknown> })
    .eq('id', row.id);

  // Postgres sweep runs ONLY if subsystems either completed or are
  // explicitly marked manual/client-action (best-effort acceptable).
  // A subsystem with `error` AND no `requires_manual_action` blocks the
  // sweep — we don't want to lose the user's row before fixable errors
  // are resolved.
  const blockingErrors: string[] = [];
  for (const key of ['posthog', 'sentry', 'revenuecat', 'cloudkit'] as SubsystemKey[]) {
    const r = ctx.refs[key];
    if (!r) continue;
    if (r.completed_at || r.requires_manual_action || r.requires_client_action) continue;
    if (r.error) blockingErrors.push(`${key}: ${r.error}`);
  }

  if (blockingErrors.length > 0) {
    const reason = truncate(
      `subsystem_failure: ${blockingErrors.join('; ')}`,
      FAILURE_REASON_MAX,
    );
    await client
      .from('deletion_requests')
      .update({
        state: 'failed',
        failure_reason: reason,
      })
      .eq('id', row.id);

    capturePosthogEvent(log, {
      event: 'deletion_request_failed',
      distinctId: row.canonical_user_key_hash,
      properties: {
        deletion_request_id: row.id,
        failure_reason: reason,
      },
    });

    return 'failed';
  }

  // All subsystems either completed or marked manual/client-action.
  // Run the postgres sweep.
  ctx.refs.postgres = await stepPostgres(ctx, client);

  if (ctx.refs.postgres.error || !ctx.refs.postgres.completed_at) {
    // Postgres sweep failed AFTER subsystems succeeded. Re-flip to
    // 'failed' so ops can retry. external_refs_json carries the
    // completed subsystem state so the retry skips them.
    await client
      .from('deletion_requests')
      .update({
        state: 'failed',
        external_refs_json: ctx.refs as Record<string, unknown>,
        failure_reason: truncate(
          `postgres_sweep: ${ctx.refs.postgres.error ?? 'unknown'}`,
          FAILURE_REASON_MAX,
        ),
      })
      .eq('id', row.id);

    capturePosthogEvent(log, {
      event: 'deletion_request_failed',
      distinctId: row.canonical_user_key_hash,
      properties: {
        deletion_request_id: row.id,
        failure_reason: 'postgres_sweep_error',
      },
    });
    return 'failed';
  }

  // Postgres sweep CASCADEd; the deletion_requests row is gone. The
  // audit_log row is the surviving anchor. Capture the success event
  // using the row id we already had in memory.
  capturePosthogEvent(log, {
    event: 'deletion_request_completed',
    distinctId: row.canonical_user_key_hash,
    properties: {
      deletion_request_id: row.id,
      had_manual_actions: !!(
        ctx.refs.sentry?.requires_manual_action ||
        ctx.refs.revenuecat?.requires_manual_action
      ),
      requires_client_action: !!ctx.refs.cloudkit?.requires_client_action,
    },
  });

  // If any subsystem requires manual action, count this as partial — the
  // privacy promise is met for server-side data, but ops triage may still
  // be needed for unconfigured external services.
  const hadManual = !!(
    ctx.refs.sentry?.requires_manual_action ||
    ctx.refs.revenuecat?.requires_manual_action
  );
  return hadManual ? 'partial' : 'completed';
}

async function fulfillSweep(
  client: ReturnType<typeof createServiceClient>,
  log: Logger,
): Promise<WorkerSummary> {
  const summary: WorkerSummary = {
    claimed: 0,
    completed: 0,
    failed: 0,
    partial: 0,
  };

  // Claim up to CLAIM_LIMIT rows in 'approved' state. Atomic transition
  // via UPDATE ... RETURNING; rows in 'processing' are left alone (ops
  // intervention path).
  const { data: claimed, error: claimErr } = await client
    .from('deletion_requests')
    .update({ state: 'processing', started_at: new Date().toISOString() })
    .eq('state', 'approved')
    .select('id, canonical_user_key, canonical_user_key_hash, external_refs_json')
    .limit(CLAIM_LIMIT);

  if (claimErr) {
    log.error('deletion_fulfill_claim_failed', { err: claimErr.message });
    return summary;
  }

  if (!claimed || claimed.length === 0) return summary;

  summary.claimed = claimed.length;

  for (const row of claimed) {
    try {
      const outcome = await processOne(client, row, log);
      if (outcome === 'completed') summary.completed += 1;
      else if (outcome === 'partial') summary.partial += 1;
      else summary.failed += 1;
    } catch (err) {
      log.error('deletion_fulfill_unhandled_exception', {
        deletion_request_id: row.id,
        err: truncate(String(err), 500),
      });
      // Hard failure: re-flip to 'failed' so the row doesn't sit in
      // 'processing' forever.
      await client
        .from('deletion_requests')
        .update({
          state: 'failed',
          failure_reason: truncate(`unhandled: ${String(err)}`, FAILURE_REASON_MAX),
        })
        .eq('id', row.id);
      summary.failed += 1;
    }
  }

  return summary;
}

// ---- HTTP entrypoint ----

const RequestSchema = z.object({}).strict().optional();

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') {
    return jsonError(ErrorCode.METHOD_NOT_ALLOWED_01, 405, { message: 'POST required' });
  }

  const auth = authorize(req);
  if (!auth.ok) {
    return jsonError(ErrorCode.AUTH_01, 401, {
      message: `Missing or invalid users-deletion-fulfill cron secret (${auth.reason}).`,
      reason: 'signature_invalid' as never,
    });
  }

  // Body is optional / empty — cron passes `{}`.
  try {
    const raw = await req.json().catch(() => ({}));
    RequestSchema.parse(raw);
  } catch (_err) {
    return jsonError(ErrorCode.VAL_01, 400, { message: 'invalid_body' });
  }

  const requestId = requestIdFrom(req);
  const log = await createLogger(requestId, 'users-deletion-fulfill');

  const client = createServiceClient();
  const summary = await fulfillSweep(client, log);

  log.info('deletion_fulfill_tick', {
    claimed: summary.claimed,
    completed: summary.completed,
    failed: summary.failed,
    partial: summary.partial,
  });

  return jsonOk({ ok: true, summary });
});

// ---- Helpers ----

function truncate(s: string, max: number): string {
  if (s.length <= max) return s;
  return s.slice(0, max - 1) + '…';
}

// Exported for testing; the test harness invokes processOne directly
// against a service-role client.
export { fulfillSweep, processOne };
