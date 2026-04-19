// Rate limiter — thin TypeScript wrapper around stir_rate_limit_check() RPC.
//
// Atomic sliding-window check-and-increment backed by rate_limit_buckets
// (migration 20260418000013). Handlers call `enforce(policy, bucketKey,
// client)` and either proceed or receive a typed RATE-01 response.
//
// Policies are hardcoded here in step 3. Tradeoff: simple + fast + no
// ops console needed. If tuning becomes frequent, migrate to a
// rate_limit_policies table in step 8 when the ops surface lands.
//
// Bucket key choice:
//   - IP policies: source IP from x-forwarded-for (first hop; trust
//     Supabase's gateway to set it correctly)
//   - user policies: canonical_user_key
//
// Conservative default on IP extraction failure: treat as same bucket
// (worst case over-rate-limits a single abuser; legitimate users
// behind shared NAT get ~30 solves/day which covers any household).

import type { SupabaseClient } from '@supabase/supabase-js';
import { ErrorCode } from './errors.ts';

export type RateLimitPolicyKey =
  | 'ip:dinner_solve_daily'
  | 'ip:pantry_parse_daily'
  | 'user:dinner_solve_hourly';

export interface RateLimitPolicy {
  windowSeconds: number;
  maxCount: number;
}

/**
 * Hardcoded policy table. Tuned per CLAUDE.md §Deferred:
 *   - IP dinner_solve 30/day: Apple-ID rotation defense
 *   - IP pantry_parse 100/day: generous; parse is cheap and abused less
 *   - user dinner_solve 10/hour: burst protection over monthly quota
 */
export const RATE_LIMIT_POLICIES: Readonly<Record<RateLimitPolicyKey, RateLimitPolicy>> = {
  'ip:dinner_solve_daily':    { windowSeconds: 86400, maxCount: 30 },
  'ip:pantry_parse_daily':    { windowSeconds: 86400, maxCount: 100 },
  'user:dinner_solve_hourly': { windowSeconds: 3600,  maxCount: 10 },
};

export interface RateLimitResult {
  allowed: boolean;
  current_count: number;
  reset_at: string; // ISO
  retry_after_seconds: number;
}

/**
 * Raw check-and-increment. Returns the RPC result — does NOT build a
 * Response. Callers that short-circuit can use the typed result for
 * telemetry before constructing the 429 body.
 */
export async function checkAndIncrement(
  client: SupabaseClient,
  scopeKey: RateLimitPolicyKey,
  bucketKey: string,
): Promise<RateLimitResult> {
  const policy = RATE_LIMIT_POLICIES[scopeKey];
  const { data, error } = await client.rpc('stir_rate_limit_check', {
    p_scope_key: scopeKey,
    p_bucket_key: bucketKey,
    p_window_seconds: policy.windowSeconds,
    p_max_count: policy.maxCount,
  });
  if (error) throw error;
  // RPC returns a SETOF row; supabase-js returns it as an array of one.
  const row = Array.isArray(data) ? data[0] : data;
  if (!row) throw new Error('stir_rate_limit_check returned no rows');
  return row as RateLimitResult;
}

/**
 * Enforce a policy. If the request is over limit, returns a ready-to-return
 * Response (RATE-01). If allowed, returns undefined and the caller proceeds.
 *
 * The returned Response includes retry_after_seconds in both the body and
 * the standard Retry-After header so iOS can schedule a local countdown
 * without re-parsing the body.
 */
export async function enforce(
  client: SupabaseClient,
  scopeKey: RateLimitPolicyKey,
  bucketKey: string,
  requestId: string,
): Promise<Response | undefined> {
  const result = await checkAndIncrement(client, scopeKey, bucketKey);
  if (result.allowed) return undefined;
  const body = {
    error: ErrorCode.RATE_01,
    message: "You've used all of this month's available actions for your plan.",
    scope: scopeKey,
    retry_after_seconds: result.retry_after_seconds,
    reset_at: result.reset_at,
  };
  return new Response(JSON.stringify(body), {
    status: 429,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'retry-after': String(result.retry_after_seconds),
      ...(requestId ? { 'x-request-id': requestId } : {}),
    },
  });
}

/**
 * Best-effort source IP extraction from request headers. Returns the
 * leftmost x-forwarded-for entry (trusted since Supabase's gateway sets
 * it), else cf-connecting-ip, else the connection remote addr (not
 * accessible on Deno.serve so we fall through to 'unknown').
 *
 * ASSUMPTION: Supabase's edge gateway always populates x-forwarded-for.
 * If a request arrives without it we bucket under 'unknown', which
 * makes multiple unknown-sourced callers share a single rate limit —
 * aggressive on purpose; we'd rather rate-limit bad actors together
 * than silently let them through.
 */
export function extractSourceIP(req: Request): string {
  const xff = req.headers.get('x-forwarded-for');
  if (xff) {
    const first = xff.split(',')[0]?.trim();
    if (first) return first;
  }
  const cf = req.headers.get('cf-connecting-ip');
  if (cf) return cf.trim();
  return 'unknown';
}
