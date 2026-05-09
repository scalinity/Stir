// POST /v1/ops/admin — single router endpoint for all admin actions.
//
// Auth: Supabase Auth magic-link JWT (NOT iOS session JWT). See ADR 0023.
// Call shape (discriminated union):
//   POST /functions/v1/ops-admin
//   Authorization: Bearer <supabase_auth_jwt>
//   Body: { "action": "users.list", "params": {...} }
//
// Response (success):
//   { "ok": true, ...action-specific payload..., "audit_id"?: "<uuid>" }
// Response (failure):
//   { "error": "AUTH-01"|"VAL-01"|"NET-01", "message": "...", "reason"?: "..." }
//
// Every mutation action writes an audit_log row via _shared/audit.ts.
// Per-action handlers live in this file as a closed switch; Phase-2 ships
// 2 actions (users.list, users.force_reauth); remaining 9 ship in P2.4.

import { z, ZodError } from 'zod';
import { createServiceClient } from '../_shared/db.ts';
import {
  AdminAuthError,
  adminAuthErrorHttp,
  type AdminIdentity,
  verifyAdminAuth,
} from '../_shared/admin_auth.ts';
import { writeAudit } from '../_shared/audit.ts';
import {
  createLogger,
  type Logger,
  requestIdFrom,
  sanitizeErrorForLog,
} from '../_shared/logger.ts';
import { ErrorCode, jsonError, jsonOk } from '../_shared/errors.ts';
import { zodToFieldErrors } from '../_shared/validation.ts';
import {
  buildRate01Response,
  checkAndIncrement,
  extractSourceIP,
  ipBucket,
} from '../_shared/rate_limiter.ts';
import { capturePosthogEvent } from '../_shared/posthog.ts';
import { hashCanonicalKey } from '../_shared/hashing.ts';
import { validateCannedFallback } from '../_shared/canned_fallback_schemas.ts';

// Typed, recoverable handler failure. Throw this from a handler when the
// error class is a user-input problem (not found / already resolved /
// bad combo) or a known infra signal — the top-level catch translates
// into a shaped jsonError with the correct status and code.
// Unknown errors fall through to a generic NET_01 500.
class DispatchError extends Error {
  readonly code: ErrorCode;
  readonly status: number;
  constructor(code: ErrorCode, status: number, message: string) {
    super(message);
    this.name = 'DispatchError';
    this.code = code;
    this.status = status;
  }
}

// ---------------------------------------------------------------------------
// Action schemas (discriminated union). 11 actions total per spec §14.
// ---------------------------------------------------------------------------

const CanonicalUserKey = z.string().min(4).max(300);
const FeatureKey = z.enum(['dinner_solve', 'voice_cook_session', 'recipe_import']);
const UserStatus = z.enum(['active', 'banned']); // 'merged' forbidden at API layer

const UsersListParams = z.object({
  tier: z.enum(['free', 'premium', 'pro']).optional(),
  search: z.string().max(256).optional(),
  limit: z.number().int().min(1).max(200).optional(),
  offset: z.number().int().min(0).optional(),
}).strict();

const UsersDetailParams = z.object({
  canonical_user_key: CanonicalUserKey,
}).strict();

const UsersResetQuotaParams = z.object({
  canonical_user_key: CanonicalUserKey,
  feature_key: FeatureKey,
}).strict();

const UsersStatusParams = z.object({
  canonical_user_key: CanonicalUserKey,
  status: UserStatus,
}).strict();

const UsersForceReauthParams = z.object({
  canonical_user_key: CanonicalUserKey,
}).strict();

const FlaggedOutputsListParams = z.object({
  state: z.enum(['open', 'resolved', 'all']).optional(),
  feature_key: z.string().max(64).optional(),
  limit: z.number().int().min(1).max(200).optional(),
  offset: z.number().int().min(0).optional(),
}).strict();

// Review W23 (SA1 W2): canned_fallback_json was z.unknown() — anything
// goes. The admin-supplied payload lands in ai_response_cache.response_body
// and is decoded by iOS on the next cache hit. A malformed paste or a
// payload that doesn't match iOS's feature-specific shape causes silent
// decode failures or wrong-content rendering. Minimum defense: require an
// object (not a bare primitive / string / array) and cap serialized size
// at 64 KiB. Per-feature schema-registry validation is a step-9 follow-up
// (CLAUDE.md §Deferred).
const CANNED_FALLBACK_MAX_BYTES = 65_536;

const FlaggedOutputsResolveParams = z.object({
  id: z.string().uuid(),
  action: z.enum(['dismissed', 'withdrawn', 'canned_fallback_pinned']),
  resolution_notes: z.string().max(2000).optional(),
  // Required iff action === 'canned_fallback_pinned'. Must be a JSON object
  // within 64 KiB serialized (matches SQL CHECK in migration 20260424000005).
  canned_fallback_json: z
    .record(z.unknown())
    .refine((v) => JSON.stringify(v).length <= CANNED_FALLBACK_MAX_BYTES, {
      message: `canned_fallback_json exceeds ${CANNED_FALLBACK_MAX_BYTES}-byte serialized cap`,
    })
    .optional(),
}).strict();

const CostAnomaliesListParams = z.object({
  resolved: z.boolean().optional(),
  severity: z.enum(['warn', 'critical']).optional(),
  since_iso: z.string().datetime().optional(),
  limit: z.number().int().min(1).max(200).optional(),
}).strict();

const VoiceSessionsListParams = z.object({
  since_iso: z.string().datetime().optional(),
  min_tokens: z.number().int().min(0).optional(),
  limit: z.number().int().min(1).max(500).optional(),
}).strict();

const PromptVersionsRolloutParams = z.object({
  feature_key: z.string().min(1).max(64),
  version: z.string().min(1).max(32),
  rollout_pct: z.number().int().min(0).max(100),
  is_default: z.boolean().optional(),
}).strict();

// SCA-61. Deletion-request triage. Listing supports the standard
// state filter; approval flips state from pending → approved and
// stamps approved_by_admin_id + approved_at. Actual fulfillment
// (CloudKit zone delete + cross-system erase) is handled by the
// pgmq-dispatch worker downstream — see SCA-88 follow-up.
const DeletionRequestsListParams = z.object({
  state: z.enum(['pending', 'approved', 'processing', 'completed', 'failed']).optional(),
  limit: z.number().int().min(1).max(500).optional(),
  offset: z.number().int().min(0).optional(),
}).strict();

const DeletionRequestsApproveParams = z.object({
  id: z.string().uuid(),
}).strict();

const FeatureFlagsUpdateParams = z.object({
  key: z.string().min(1).max(128),
  value: z.unknown().optional(),
  is_enabled: z.boolean().optional(),
  rollout_pct: z.number().int().min(0).max(100).optional(),
}).strict();

const AdminActionSchema = z.discriminatedUnion('action', [
  z.object({ action: z.literal('users.list'), params: UsersListParams.default({}) }).strict(),
  z.object({ action: z.literal('users.detail'), params: UsersDetailParams }).strict(),
  z.object({ action: z.literal('users.reset_quota'), params: UsersResetQuotaParams }).strict(),
  z.object({ action: z.literal('users.status'), params: UsersStatusParams }).strict(),
  z.object({ action: z.literal('users.force_reauth'), params: UsersForceReauthParams }).strict(),
  z.object({
    action: z.literal('flagged_outputs.list'),
    params: FlaggedOutputsListParams.default({}),
  }).strict(),
  z.object({ action: z.literal('flagged_outputs.resolve'), params: FlaggedOutputsResolveParams })
    .strict(),
  z.object({
    action: z.literal('cost_anomalies.list'),
    params: CostAnomaliesListParams.default({}),
  }).strict(),
  z.object({
    action: z.literal('voice_sessions.list'),
    params: VoiceSessionsListParams.default({}),
  }).strict(),
  z.object({ action: z.literal('prompt_versions.rollout'), params: PromptVersionsRolloutParams })
    .strict(),
  z.object({ action: z.literal('feature_flags.update'), params: FeatureFlagsUpdateParams })
    .strict(),
  z.object({
    action: z.literal('deletion_requests.list'),
    params: DeletionRequestsListParams.default({}),
  }).strict(),
  z.object({ action: z.literal('deletion_requests.approve'), params: DeletionRequestsApproveParams })
    .strict(),
]);

type AdminAction = z.infer<typeof AdminActionSchema>;

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  const requestId = requestIdFrom(req);
  const endpoint = '/v1/ops/admin';
  const log = await createLogger(requestId, endpoint);

  if (req.method !== 'POST') {
    return jsonError(
      ErrorCode.METHOD_NOT_ALLOWED_01,
      405,
      { message: 'Method Not Allowed; use POST.', allowed: ['POST'] },
      requestId,
    );
  }

  const client = createServiceClient();

  // 1. Admin auth gate — triple-check iss/aud/UUID-sub, then ops_admins lookup.
  let admin: AdminIdentity;
  try {
    admin = await verifyAdminAuth(req, client);
  } catch (err) {
    if (err instanceof AdminAuthError) {
      const http = adminAuthErrorHttp(err);
      log.warn('admin_auth_reject', { reason: err.reason });
      const code = http.reason === 'not_admin' ? ErrorCode.BILL_01 : ErrorCode.AUTH_01;
      return jsonError(
        code,
        http.status,
        code === ErrorCode.AUTH_01
          ? { reason: http.reason as never, message: err.message }
          : { message: err.message },
        requestId,
      );
    }
    log.error('admin_auth_unexpected', err);
    return jsonError(ErrorCode.NET_01, 500, undefined, requestId);
  }

  // W26 (SA3 W2): log actor_id (UUID), not actor_email. Function logs
  // have broader read visibility than audit_log; audit_log still carries
  // actor_email for support-time identity lookup.
  log.info('admin_authenticated', { actor_id: admin.authUserId });

  // 1b. IP rate limit (SA2 W2): 30/min per source IP. Legit active triage
  // rarely exceeds ~10/min; this caps a compromised-token enumeration
  // attack to 30/min, cutting thousands-per-second worst case.
  const sourceIP = extractSourceIP(req);
  try {
    const rl = await checkAndIncrement(client, 'ip:ops_admin_hourly', sourceIP);
    if (!rl.allowed) {
      log.warn('rate_limited', {
        scope: 'ip:ops_admin_hourly',
        source_ip_bucket: await ipBucket(sourceIP),
      });
      return buildRate01Response(
        'ip:ops_admin_hourly',
        rl.retry_after_seconds,
        rl.reset_at,
        requestId,
      );
    }
  } catch (err) {
    // Fail open — a rate_limit_buckets glitch must not lock the console.
    log.warn('rate_limiter_failed', { err: sanitizeErrorForLog(err) });
  }

  // 1c. Per-admin rate limit (SCA-117): 60/min keyed on admin.authUserId.
  // Layered defense above the IP cap — catches a compromised single
  // admin token that rotates source IPs to bypass the IP-scoped check.
  // First-to-trip wins; RATE-01 `scope` distinguishes which gate fired
  // so the SPA can show "your account is rate-limited" vs "your IP is."
  // Same fail-open posture as 1b — bucket glitches must not lock out
  // legit ops triage.
  try {
    const rl = await checkAndIncrement(client, 'user:ops_admin_minutely', admin.authUserId);
    if (!rl.allowed) {
      log.warn('rate_limited', {
        scope: 'user:ops_admin_minutely',
        actor_id: admin.authUserId,
      });
      return buildRate01Response(
        'user:ops_admin_minutely',
        rl.retry_after_seconds,
        rl.reset_at,
        requestId,
      );
    }
  } catch (err) {
    log.warn('rate_limiter_failed', { err: sanitizeErrorForLog(err) });
  }

  // 2. Body validation.
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return jsonError(
      ErrorCode.VAL_01,
      400,
      { field_errors: [{ field: 'body', issue: 'request body must be JSON' }] },
      requestId,
    );
  }

  let parsed: AdminAction;
  try {
    parsed = AdminActionSchema.parse(body);
  } catch (err) {
    if (err instanceof ZodError) {
      return jsonError(
        ErrorCode.VAL_01,
        400,
        { field_errors: zodToFieldErrors(err) },
        requestId,
      );
    }
    throw err;
  }

  // 3. Dispatch.
  try {
    const payload = await dispatch(parsed, { client, admin, log, requestId });
    return jsonOk(payload, requestId);
  } catch (err) {
    // Typed handler failures get the intended status + code. Unknown
    // errors fall through to NET-01 500 — the raw message is logged at
    // error level (internal detail only) and replaced with a sanitized
    // string in the response body. Review W1/W17 fix.
    if (err instanceof DispatchError) {
      log.warn('action_rejected', {
        action: parsed.action,
        code: err.code,
        status: err.status,
        message: err.message,
      });
      return jsonError(err.code, err.status, { message: err.message }, requestId);
    }
    log.error('action_failed', err, { action: parsed.action });
    return jsonError(
      ErrorCode.NET_01,
      500,
      { message: 'Internal error; see Supabase function logs.' },
      requestId,
    );
  }
});

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

interface HandlerCtx {
  client: ReturnType<typeof createServiceClient>;
  admin: AdminIdentity;
  log: Logger;
  requestId: string;
}

async function dispatch(parsed: AdminAction, ctx: HandlerCtx): Promise<Record<string, unknown>> {
  switch (parsed.action) {
    case 'users.list':
      return await handleUsersList(parsed.params, ctx);
    case 'users.detail':
      return await handleUsersDetail(parsed.params, ctx);
    case 'users.reset_quota':
      return await handleUsersResetQuota(parsed.params, ctx);
    case 'users.status':
      return await handleUsersStatus(parsed.params, ctx);
    case 'users.force_reauth':
      return await handleUsersForceReauth(parsed.params, ctx);
    case 'flagged_outputs.list':
      return await handleFlaggedOutputsList(parsed.params, ctx);
    case 'flagged_outputs.resolve':
      return await handleFlaggedOutputsResolve(parsed.params, ctx);
    case 'cost_anomalies.list':
      return await handleCostAnomaliesList(parsed.params, ctx);
    case 'voice_sessions.list':
      return await handleVoiceSessionsList(parsed.params, ctx);
    case 'prompt_versions.rollout':
      return await handlePromptVersionsRollout(parsed.params, ctx);
    case 'feature_flags.update':
      return await handleFeatureFlagsUpdate(parsed.params, ctx);
    case 'deletion_requests.list':
      return await handleDeletionRequestsList(parsed.params, ctx);
    case 'deletion_requests.approve':
      return await handleDeletionRequestsApprove(parsed.params, ctx);
    default: {
      // Exhaustiveness guard (review W45). TS can't narrow z.infer<any>
      // through discriminated-switch at the Zod seam, so we fall through
      // to an explicit runtime rejection rather than the pre-fix implicit
      // `undefined` return → jsonOk(undefined) → 200 with empty body.
      throw new Error(
        `unhandled admin action: ${String((parsed as { action?: string }).action ?? '<unknown>')}`,
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Action: users.list
// ---------------------------------------------------------------------------

async function handleUsersList(
  params: z.infer<typeof UsersListParams>,
  ctx: HandlerCtx,
): Promise<Record<string, unknown>> {
  const { data, error } = await ctx.client.rpc('stir_ops_list_users', {
    p_tier: params.tier ?? null,
    p_search: params.search ?? null,
    p_limit: params.limit ?? 50,
    p_offset: params.offset ?? 0,
  });
  if (error) {
    throw new Error(`stir_ops_list_users failed: ${error.message}`);
  }
  // result_count = size of the returned page (NOT total_count, which is the
  // filtered-across-pages total). Dashboard chart "did the query return
  // anything" wants the page-size count.
  const userRows = (data as { users?: unknown[] })?.users;
  await emitOpsEvent(ctx, 'ops_admin.users.list_queried', {
    tier_filter: params.tier ?? null,
    has_search: Boolean(params.search),
    limit: params.limit ?? 50,
    offset: params.offset ?? 0,
    result_count: Array.isArray(userRows) ? userRows.length : 0,
  });
  return { ok: true, ...(data as Record<string, unknown>) };
}

// ---------------------------------------------------------------------------
// Action: users.force_reauth (ADR 0023 Phase-2 contract)
// ---------------------------------------------------------------------------

async function handleUsersForceReauth(
  params: z.infer<typeof UsersForceReauthParams>,
  ctx: HandlerCtx,
): Promise<Record<string, unknown>> {
  const { data, error } = await ctx.client.rpc('stir_ops_force_reauth', {
    p_canonical_user_key: params.canonical_user_key,
  });
  if (error) {
    // W17 + W19 fix: classify SQLSTATE 22023 'user not found' as VAL-01/404
    // rather than leaking through the top-level catch as NET-01/500 with
    // raw SQL text. Any other PGRST failure is genuine infra → NET-01 500.
    const msg = String(error.message ?? '');
    if (msg.includes('user not found')) {
      throw new DispatchError(
        ErrorCode.VAL_01,
        404,
        `user not found: ${params.canonical_user_key}`,
      );
    }
    throw new Error(`stir_ops_force_reauth failed: ${msg}`);
  }

  const result = data as {
    ok: boolean;
    before: Record<string, unknown>;
    after: Record<string, unknown>;
    merged_siblings_bumped?: number;
  };

  const auditId = await writeAudit(ctx.client, ctx.log, {
    actor_id: ctx.admin.authUserId,
    actor_email: ctx.admin.email,
    action: 'users.force_reauth',
    target_table: 'app_users',
    target_id: params.canonical_user_key,
    before: { reauth_required_at: result.before.reauth_required_at },
    after: { reauth_required_at: result.after.reauth_required_at },
    request_id: ctx.requestId,
  });

  await emitOpsEvent(ctx, 'ops_admin.users.force_reauth', {
    canonical_user_key_hash: await hashCanonicalKey(params.canonical_user_key),
    merged_siblings_bumped: result.merged_siblings_bumped ?? 0,
    audit_id: auditId,
  });

  return {
    ok: true,
    canonical_user_key: params.canonical_user_key,
    reauth_required_at: result.after.reauth_required_at,
    audit_id: auditId,
  };
}

// ---------------------------------------------------------------------------
// Action: users.detail
// ---------------------------------------------------------------------------

async function handleUsersDetail(
  params: z.infer<typeof UsersDetailParams>,
  ctx: HandlerCtx,
): Promise<Record<string, unknown>> {
  const { data, error } = await ctx.client.rpc('stir_ops_user_detail', {
    p_canonical_user_key: params.canonical_user_key,
  });
  if (error) throw new Error(`stir_ops_user_detail failed: ${error.message}`);

  // W8 (SA2 W4): read-audit trail for per-user lookups. Targeted user.detail
  // queries are high-signal — a compromised admin enumerating a specific
  // user leaves a trail scoped to that user. List/search endpoints stay
  // unaudited to keep audit_log write volume bounded.
  const auditId = await writeAudit(ctx.client, ctx.log, {
    actor_id: ctx.admin.authUserId,
    actor_email: ctx.admin.email,
    action: 'users.detail.viewed',
    target_table: 'app_users',
    target_id: params.canonical_user_key,
    before: null,
    after: null,
    request_id: ctx.requestId,
  });
  await emitOpsEvent(ctx, 'ops_admin.users.detail_viewed', {
    canonical_user_key_hash: await hashCanonicalKey(params.canonical_user_key),
    audit_id: auditId,
  });
  return { ok: true, detail: data, audit_id: auditId };
}

// ---------------------------------------------------------------------------
// Action: users.reset_quota
// ---------------------------------------------------------------------------

async function handleUsersResetQuota(
  params: z.infer<typeof UsersResetQuotaParams>,
  ctx: HandlerCtx,
): Promise<Record<string, unknown>> {
  const { data, error } = await ctx.client.rpc('stir_ops_reset_quota', {
    p_canonical_user_key: params.canonical_user_key,
    p_feature_key: params.feature_key,
  });
  if (error) throw new Error(`stir_ops_reset_quota failed: ${error.message}`);
  const result = data as { ok: boolean; before: unknown; after: unknown; noop?: boolean };

  const auditId = await writeAudit(ctx.client, ctx.log, {
    actor_id: ctx.admin.authUserId,
    actor_email: ctx.admin.email,
    action: 'users.reset_quota',
    target_table: 'usage_counters',
    target_id: `${params.canonical_user_key}:${params.feature_key}`,
    before: result.before,
    after: result.after,
    request_id: ctx.requestId,
  });

  await emitOpsEvent(ctx, 'ops_admin.users.quota_reset', {
    canonical_user_key_hash: await hashCanonicalKey(params.canonical_user_key),
    feature_key: params.feature_key,
    noop: result.noop ?? false,
    audit_id: auditId,
  });

  return { ...result, audit_id: auditId };
}

// ---------------------------------------------------------------------------
// Action: users.status
// ---------------------------------------------------------------------------

async function handleUsersStatus(
  params: z.infer<typeof UsersStatusParams>,
  ctx: HandlerCtx,
): Promise<Record<string, unknown>> {
  const { data, error } = await ctx.client.rpc('stir_ops_set_user_status', {
    p_canonical_user_key: params.canonical_user_key,
    p_status: params.status,
  });
  if (error) throw new Error(`stir_ops_set_user_status failed: ${error.message}`);
  const result = data as { ok: boolean; before: unknown; after: unknown };

  const auditId = await writeAudit(ctx.client, ctx.log, {
    actor_id: ctx.admin.authUserId,
    actor_email: ctx.admin.email,
    action: 'users.status.updated',
    target_table: 'app_users',
    target_id: params.canonical_user_key,
    before: result.before,
    after: result.after,
    request_id: ctx.requestId,
  });

  // from_status reads the prior status off result.before (the to_jsonb
  // snapshot the RPC returns); falls back to null if the shape ever drifts
  // so the emit doesn't error out.
  const fromStatus = (result.before as { status?: string } | null)?.status ?? null;

  await emitOpsEvent(ctx, 'ops_admin.users.status_changed', {
    canonical_user_key_hash: await hashCanonicalKey(params.canonical_user_key),
    from_status: fromStatus,
    to_status: params.status,
    audit_id: auditId,
  });

  return { ...result, audit_id: auditId };
}

// ---------------------------------------------------------------------------
// Action: flagged_outputs.list
// ---------------------------------------------------------------------------

async function handleFlaggedOutputsList(
  params: z.infer<typeof FlaggedOutputsListParams>,
  ctx: HandlerCtx,
): Promise<Record<string, unknown>> {
  const state = params.state ?? 'open';
  const limit = params.limit ?? 50;
  const offset = params.offset ?? 0;

  let query = ctx.client
    .from('ops_flagged_outputs')
    .select('*', { count: 'exact' })
    .order('created_at', { ascending: false });

  if (state === 'open') query = query.is('resolved_at', null);
  else if (state === 'resolved') query = query.not('resolved_at', 'is', null);
  if (params.feature_key) query = query.eq('feature_key', params.feature_key);

  const { data, error, count } = await query.range(offset, offset + limit - 1);
  if (error) throw new Error(`flagged_outputs query failed: ${error.message}`);

  return { ok: true, rows: data ?? [], total_count: count ?? 0, limit, offset };
}

// ---------------------------------------------------------------------------
// Action: flagged_outputs.resolve
// ---------------------------------------------------------------------------
//
// Per ADR 0023 §D3 three-action resolution enum:
//   dismissed              = passive review; no cache mutation
//   withdrawn              = active removal; DELETE the ai_response_cache row
//   canned_fallback_pinned = replacement; UPDATE ai_response_cache with
//                             canned_fallback_json

async function handleFlaggedOutputsResolve(
  params: z.infer<typeof FlaggedOutputsResolveParams>,
  ctx: HandlerCtx,
): Promise<Record<string, unknown>> {
  // Require canned_fallback_json iff action is canned_fallback_pinned.
  if (params.action === 'canned_fallback_pinned' && params.canned_fallback_json === undefined) {
    throw new DispatchError(
      ErrorCode.VAL_01,
      400,
      'canned_fallback_json required for canned_fallback_pinned action',
    );
  }
  if (params.action !== 'canned_fallback_pinned' && params.canned_fallback_json !== undefined) {
    throw new DispatchError(
      ErrorCode.VAL_01,
      400,
      'canned_fallback_json only allowed for canned_fallback_pinned action',
    );
  }

  // Fetch the flagged row to get the request_id + canonical_user_key_hash for
  // cache side-effects.
  const { data: flagged, error: fetchErr } = await ctx.client
    .from('ops_flagged_outputs')
    .select('id, request_id, canonical_user_key_hash, feature_key, resolved_at')
    .eq('id', params.id)
    .single();
  if (fetchErr || !flagged) {
    throw new DispatchError(ErrorCode.VAL_01, 404, `flagged_output ${params.id} not found`);
  }
  if (flagged.resolved_at) {
    throw new DispatchError(ErrorCode.VAL_01, 409, `flagged_output ${params.id} already resolved`);
  }

  // SCA-81: validate canned_fallback_json against the per-feature
  // top-level-key allowlist. Refuse the resolve if the payload doesn't
  // structurally match the feature's response shape — a malformed
  // paste would otherwise land in ai_response_cache and break iOS
  // decode on the next cache hit.
  if (params.action === 'canned_fallback_pinned' && params.canned_fallback_json !== undefined) {
    const errors = validateCannedFallback(flagged.feature_key, params.canned_fallback_json);
    if (errors.length > 0) {
      throw new DispatchError(
        ErrorCode.VAL_01,
        400,
        `canned_fallback_json shape invalid for feature_key '${flagged.feature_key}': ${
          errors.map((e) => `${e.field} → ${e.issue}`).join('; ')
        }`,
      );
    }
  }

  // Cache side-effects BEFORE the resolve write so failures surface loudly.
  //
  // User-scope the mutation (review C2 + SA3 W3): ai_response_cache's PK is
  // (canonical_user_key, request_id) per migration 20260418000024. Filtering
  // only by request_id would delete/overwrite cache rows for every user
  // who happens to share that request_id, breaking the per-user scoping
  // invariant that migration introduced.
  //
  // The flagged row carries only canonical_user_key_hash (irreversible),
  // so we join through ai_request_log — that table stores the raw
  // canonical_user_key alongside request_id. Fail closed if the owner
  // can't be resolved (orphan flag from deleted ai_request_log row) to
  // avoid the wildcard-delete fallthrough.
  if (params.action === 'withdrawn' || params.action === 'canned_fallback_pinned') {
    const { data: ownerRow, error: ownerErr } = await ctx.client
      .from('ai_request_log')
      .select('canonical_user_key')
      .eq('request_id', flagged.request_id)
      .maybeSingle<{ canonical_user_key: string }>();

    if (ownerErr) {
      throw new Error(`resolve owner lookup failed: ${ownerErr.message}`);
    }
    if (!ownerRow) {
      throw new Error(
        `resolve owner lookup: no ai_request_log row for request_id ${flagged.request_id} — cannot scope cache mutation safely`,
      );
    }

    if (params.action === 'withdrawn') {
      const { error: deleteErr } = await ctx.client
        .from('ai_response_cache')
        .delete()
        .eq('canonical_user_key', ownerRow.canonical_user_key)
        .eq('request_id', flagged.request_id);
      // W38 (DB1 #4): surface cache mutation errors before the resolve
      // write so admins can retry.
      if (deleteErr) {
        throw new Error(`ai_response_cache delete failed: ${deleteErr.message}`);
      }
    } else {
      // canned_fallback_pinned — replace with admin-supplied safe fallback.
      const { error: updateCacheErr } = await ctx.client
        .from('ai_response_cache')
        .update({ response_body: params.canned_fallback_json })
        .eq('canonical_user_key', ownerRow.canonical_user_key)
        .eq('request_id', flagged.request_id);
      if (updateCacheErr) {
        throw new Error(`ai_response_cache update failed: ${updateCacheErr.message}`);
      }
    }
  }

  // Update the flagged row itself.
  const { data: updated, error: updateErr } = await ctx.client
    .from('ops_flagged_outputs')
    .update({
      resolved_at: new Date().toISOString(),
      resolved_by: ctx.admin.authUserId,
      resolution_action: params.action,
      resolution_notes: params.resolution_notes ?? null,
      canned_fallback_json: params.canned_fallback_json ?? null,
    })
    .eq('id', params.id)
    .select('*')
    .single();
  if (updateErr) throw new Error(`flagged_output resolve failed: ${updateErr.message}`);

  const auditId = await writeAudit(ctx.client, ctx.log, {
    actor_id: ctx.admin.authUserId,
    actor_email: ctx.admin.email,
    action: `flagged_outputs.resolved.${params.action}`,
    target_table: 'ops_flagged_outputs',
    target_id: params.id,
    before: { resolved_at: null, resolution_action: null },
    after: {
      resolved_at: updated?.resolved_at,
      resolution_action: updated?.resolution_action,
    },
    request_id: ctx.requestId,
  });

  await emitOpsEvent(ctx, 'ops_admin.flagged_outputs.resolved', {
    feature_key: flagged.feature_key,
    resolution_action: params.action,
    target_id: params.id,
    audit_id: auditId,
  });

  return { ok: true, flagged_output: updated, audit_id: auditId };
}

// ---------------------------------------------------------------------------
// Action: cost_anomalies.list
// ---------------------------------------------------------------------------

async function handleCostAnomaliesList(
  params: z.infer<typeof CostAnomaliesListParams>,
  ctx: HandlerCtx,
): Promise<Record<string, unknown>> {
  const limit = params.limit ?? 50;
  let query = ctx.client
    .from('cost_anomalies')
    .select('*', { count: 'exact' })
    .order('detected_at', { ascending: false });

  if (params.resolved === true) query = query.not('resolved_at', 'is', null);
  if (params.resolved === false) query = query.is('resolved_at', null);
  if (params.severity) query = query.eq('severity', params.severity);
  if (params.since_iso) query = query.gte('detected_at', params.since_iso);

  const { data, error, count } = await query.limit(limit);
  if (error) throw new Error(`cost_anomalies query failed: ${error.message}`);

  return { ok: true, rows: data ?? [], total_count: count ?? 0, limit };
}

// ---------------------------------------------------------------------------
// Action: voice_sessions.list
// ---------------------------------------------------------------------------

async function handleVoiceSessionsList(
  params: z.infer<typeof VoiceSessionsListParams>,
  ctx: HandlerCtx,
): Promise<Record<string, unknown>> {
  const { data, error } = await ctx.client.rpc('stir_ops_list_voice_sessions', {
    p_since: params.since_iso ?? null,
    p_min_tokens: params.min_tokens ?? 0,
    p_limit: params.limit ?? 100,
  });
  if (error) throw new Error(`stir_ops_list_voice_sessions failed: ${error.message}`);
  return { ok: true, ...(data as Record<string, unknown>) };
}

// ---------------------------------------------------------------------------
// Action: prompt_versions.rollout
// ---------------------------------------------------------------------------

async function handlePromptVersionsRollout(
  params: z.infer<typeof PromptVersionsRolloutParams>,
  ctx: HandlerCtx,
): Promise<Record<string, unknown>> {
  // prompt_versions has composite PK (feature_key, version); no synthetic id.
  const { data: before, error: preErr } = await ctx.client
    .from('prompt_versions')
    .select('feature_key, version, rollout_pct, is_default')
    .eq('feature_key', params.feature_key)
    .eq('version', params.version)
    .single();
  if (preErr || !before) {
    throw new DispatchError(
      ErrorCode.VAL_01,
      404,
      `prompt_version ${params.feature_key}@${params.version} not found`,
    );
  }

  // Single-default-per-feature invariant: clear the flag on siblings first.
  if (params.is_default === true) {
    await ctx.client
      .from('prompt_versions')
      .update({ is_default: false })
      .eq('feature_key', params.feature_key)
      .neq('version', params.version);
  }

  const updates: Record<string, unknown> = { rollout_pct: params.rollout_pct };
  if (params.is_default !== undefined) updates.is_default = params.is_default;

  const { data: after, error: updateErr } = await ctx.client
    .from('prompt_versions')
    .update(updates)
    .eq('feature_key', params.feature_key)
    .eq('version', params.version)
    .select('feature_key, version, rollout_pct, is_default')
    .single();
  if (updateErr) throw new Error(`prompt_versions update failed: ${updateErr.message}`);

  const auditId = await writeAudit(ctx.client, ctx.log, {
    actor_id: ctx.admin.authUserId,
    actor_email: ctx.admin.email,
    action: 'prompt_versions.rollout',
    target_table: 'prompt_versions',
    target_id: `${params.feature_key}@${params.version}`,
    before,
    after,
    request_id: ctx.requestId,
  });

  await emitOpsEvent(ctx, 'ops_admin.prompt_versions.rollout', {
    feature_key: params.feature_key,
    version: params.version,
    rollout_pct: params.rollout_pct,
    is_default: params.is_default ?? null,
    target_id: `${params.feature_key}@${params.version}`,
    audit_id: auditId,
  });

  return { ok: true, before, after, audit_id: auditId };
}

// ---------------------------------------------------------------------------
// Action: feature_flags.update
// ---------------------------------------------------------------------------

async function handleFeatureFlagsUpdate(
  params: z.infer<typeof FeatureFlagsUpdateParams>,
  ctx: HandlerCtx,
): Promise<Record<string, unknown>> {
  const { data: before, error: preErr } = await ctx.client
    .from('feature_flags')
    .select('key, payload_json, is_enabled, rollout_pct')
    .eq('key', params.key)
    .single();
  if (preErr || !before) {
    throw new DispatchError(ErrorCode.VAL_01, 404, `feature_flag ${params.key} not found`);
  }

  const updates: Record<string, unknown> = {};
  if (params.value !== undefined) updates.payload_json = { value: params.value };
  if (params.is_enabled !== undefined) updates.is_enabled = params.is_enabled;
  if (params.rollout_pct !== undefined) updates.rollout_pct = params.rollout_pct;

  if (Object.keys(updates).length === 0) {
    await emitOpsEvent(ctx, 'ops_admin.feature_flags.updated', {
      flag_key: params.key,
      target_id: params.key,
      noop: true,
      audit_id: null,
    });
    return { ok: true, before, after: before, audit_id: null, noop: true };
  }

  const { data: after, error: updateErr } = await ctx.client
    .from('feature_flags')
    .update(updates)
    .eq('key', params.key)
    .select('key, payload_json, is_enabled, rollout_pct')
    .single();
  if (updateErr) throw new Error(`feature_flags update failed: ${updateErr.message}`);

  const auditId = await writeAudit(ctx.client, ctx.log, {
    actor_id: ctx.admin.authUserId,
    actor_email: ctx.admin.email,
    action: 'feature_flags.updated',
    target_table: 'feature_flags',
    target_id: params.key,
    before,
    after,
    request_id: ctx.requestId,
  });

  await emitOpsEvent(ctx, 'ops_admin.feature_flags.updated', {
    flag_key: params.key,
    target_id: params.key,
    is_enabled: params.is_enabled ?? null,
    rollout_pct: params.rollout_pct ?? null,
    noop: false,
    audit_id: auditId,
  });

  return { ok: true, before, after, audit_id: auditId };
}

// ---------------------------------------------------------------------------
// Action: deletion_requests.list / deletion_requests.approve (SCA-61)
// ---------------------------------------------------------------------------

async function handleDeletionRequestsList(
  params: z.infer<typeof DeletionRequestsListParams>,
  ctx: HandlerCtx,
): Promise<Record<string, unknown>> {
  let query = ctx.client
    .from('deletion_requests')
    .select(
      // SCA-244 (C1): `completed_at` was dropped by migration
      // 20260508000008_drop_deletion_requests_completed_at.sql. ADR
      // 0033 (deletion-fulfillment-ordering) anchors success on
      // audit_log; deletion_requests rows are wiped by the cascade on
      // success. Keeping the column in this SELECT after the drop
      // produces a PostgREST `column does not exist` at every
      // deletion_requests.list call.
      'id, canonical_user_key_hash, state, requested_at, approved_at, started_at, failure_reason',
      { count: 'exact' },
    )
    .order('requested_at', { ascending: false });

  if (params.state) {
    query = query.eq('state', params.state);
  } else {
    // Default view: in-flight + recent terminal entries. The pending
    // index lives on (state, requested_at DESC), so this default is
    // also the index hot-path.
    query = query.in('state', ['pending', 'approved', 'processing', 'failed']);
  }

  const limit = params.limit ?? 100;
  const offset = params.offset ?? 0;
  query = query.range(offset, offset + limit - 1);

  const { data, error, count } = await query;
  if (error) {
    throw new Error(`deletion_requests list failed: ${error.message}`);
  }

  await emitOpsEvent(ctx, 'ops_admin.deletion_requests.list_queried', {
    state_filter: params.state ?? null,
    target_id: null,
    result_count: data?.length ?? 0,
  });

  return {
    rows: data ?? [],
    total_count: count ?? 0,
    limit,
    offset,
  };
}

async function handleDeletionRequestsApprove(
  params: z.infer<typeof DeletionRequestsApproveParams>,
  ctx: HandlerCtx,
): Promise<Record<string, unknown>> {
  const { data: before, error: preErr } = await ctx.client
    .from('deletion_requests')
    .select('id, state, canonical_user_key_hash, requested_at, approved_at')
    .eq('id', params.id)
    .single();

  if (preErr || !before) {
    throw new DispatchError(ErrorCode.VAL_01, 404, `deletion_request ${params.id} not found`);
  }
  if (before.state !== 'pending') {
    throw new DispatchError(
      ErrorCode.VAL_01,
      409,
      `deletion_request ${params.id} state is ${before.state}; only 'pending' can be approved`,
    );
  }

  const { data: after, error: updateErr } = await ctx.client
    .from('deletion_requests')
    .update({
      state: 'approved',
      approved_at: new Date().toISOString(),
      approved_by_admin_id: ctx.admin.authUserId,
      updated_at: new Date().toISOString(),
    })
    .eq('id', params.id)
    .eq('state', 'pending')
    .select('id, state, approved_at, approved_by_admin_id')
    .single();

  if (updateErr || !after) {
    throw new Error(
      `deletion_requests approve failed: ${updateErr?.message ?? 'race lost on state filter'}`,
    );
  }

  const auditId = await writeAudit(ctx.client, ctx.log, {
    actor_id: ctx.admin.authUserId,
    actor_email: ctx.admin.email,
    action: 'deletion_requests.approved',
    target_table: 'deletion_requests',
    target_id: params.id,
    before,
    after,
    request_id: ctx.requestId,
  });

  await emitOpsEvent(ctx, 'ops_admin.deletion_requests.approved', {
    deletion_request_id: params.id,
    target_id: params.id,
    target_user_hash: before.canonical_user_key_hash,
    audit_id: auditId,
  });

  return { ok: true, before, after, audit_id: auditId };
}

// ---------------------------------------------------------------------------
// PostHog ops event emit helper (Phase C — telemetry wiring bundle 2026-04-24)
//
// One emit per admin action. Per ADR 0027 + canonical-properties.md:
//   distinct_id  = hash('admin:' + admin.authUserId)  — admin's own hash, not
//                                                       the acted-on user's
//   request_id   = ctx.requestId                       — cross-system join key
//   actor_id     = admin.authUserId                    — UUID of admin
// Caller-supplied properties merge over the mandatory three.
//
// capturePosthogEvent itself is non-throwing (fire-and-forget via
// EdgeRuntime.waitUntil with internal try/catch). The outer try/catch
// here is defense-in-depth: hashCanonicalKey is async (awaits
// crypto.subtle.digest); a runtime upgrade or unexpected key-string
// shape could in principle reject the promise, and we don't want a
// telemetry path failure to unwind the user-visible mutation. Matches
// the writeAudit failure posture: log.warn, swallow, never re-throw.
// ---------------------------------------------------------------------------

async function emitOpsEvent(
  ctx: HandlerCtx,
  event: string,
  properties: Record<string, unknown>,
): Promise<void> {
  try {
    const distinctId = await hashCanonicalKey(`admin:${ctx.admin.authUserId}`);
    capturePosthogEvent(ctx.log, {
      event,
      distinctId,
      properties: {
        request_id: ctx.requestId,
        actor_id: ctx.admin.authUserId,
        ...properties,
      },
    });
  } catch (err) {
    ctx.log.warn('posthog_emit_failed', {
      event,
      err: err instanceof Error ? err.message : String(err),
    });
  }
}

// ---------------------------------------------------------------------------
// (Helpers: zodToFieldErrors imported from _shared/validation.ts since W18 fix.)
