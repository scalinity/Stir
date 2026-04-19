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
  | 'ip:bootstrap_hourly'
  | 'user:dinner_solve_hourly';

export interface RateLimitPolicy {
  windowSeconds: number;
  maxCount: number;
}

/**
 * Hardcoded policy table. Tuned per CLAUDE.md §Deferred:
 *   - IP dinner_solve 30/day: Apple-ID rotation defense
 *   - IP pantry_parse 100/day: generous; parse is cheap and abused less
 *   - IP bootstrap 20/hour: stops JWT-farming + synthetic install DoS
 *     without interfering with legitimate re-launches on a shared NAT
 *   - user dinner_solve 10/hour: burst protection over monthly quota
 */
export const RATE_LIMIT_POLICIES: Readonly<Record<RateLimitPolicyKey, RateLimitPolicy>> = {
  'ip:dinner_solve_daily':    { windowSeconds: 86400, maxCount: 30 },
  'ip:pantry_parse_daily':    { windowSeconds: 86400, maxCount: 100 },
  'ip:bootstrap_hourly':      { windowSeconds: 3600,  maxCount: 20 },
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
 *
 * Private/loopback source IPs (RFC 1918, 127/8, ::1, fc00::/7) are
 * always allowed without recording a bucket increment. Reason: in
 * production the edge gateway resolves external peers to routable IPs,
 * so a private-range source can only come from internal traffic
 * (monitoring, local dev, Supabase-to-Supabase). Rate-limiting those
 * would only penalize test suites + ops tooling without blocking any
 * real abuser. If a misconfigured proxy ever starts forwarding
 * private-range IPs from external clients, the routing layer is the
 * correct place to fix it — not the rate limiter.
 */
export async function checkAndIncrement(
  client: SupabaseClient,
  scopeKey: RateLimitPolicyKey,
  bucketKey: string,
): Promise<RateLimitResult> {
  if (bucketKey.startsWith('ip:') || scopeKey.startsWith('ip:')) {
    // Only IP-scoped policies are affected by the private-IP skip; user-
    // scoped policies always run. We check the bucket key (which for IP
    // scopes is the source IP string) because the scope key alone doesn't
    // carry the peer address.
    if (isPrivateOrLoopbackIP(bucketKey)) {
      return {
        allowed: true,
        current_count: 0,
        reset_at: new Date(Date.now() + RATE_LIMIT_POLICIES[scopeKey].windowSeconds * 1000).toISOString(),
        retry_after_seconds: 0,
      };
    }
  }

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
 * Detect RFC 1918 private ranges, loopback, and IPv6 unique-local
 * addresses. Handles 'unknown' and test-fixture tokens as NOT private
 * (they should still be rate-limited — abusers who strip all headers
 * fall into the 'unknown' bucket).
 */
function isPrivateOrLoopbackIP(candidate: string): boolean {
  const ip = candidate.trim().toLowerCase();
  if (!ip || ip === 'unknown') return false;

  // IPv6 loopback + unique-local.
  if (ip === '::1') return true;
  if (ip.startsWith('fc') || ip.startsWith('fd')) return true;  // fc00::/7
  if (ip.startsWith('fe80:')) return true;  // link-local

  // IPv4: quick dotted-quad parse.
  const parts = ip.split('.');
  if (parts.length !== 4) return false;
  const octets = parts.map((p) => Number(p));
  if (octets.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return false;
  const [a, b] = octets as [number, number, number, number];
  if (a === 10) return true;                        // 10/8
  if (a === 127) return true;                       // 127/8
  if (a === 192 && b === 168) return true;          // 192.168/16
  if (a === 172 && b >= 16 && b <= 31) return true; // 172.16/12
  if (a === 169 && b === 254) return true;          // link-local 169.254/16
  return false;
}

/**
 * Build a typed 429 RATE-01 Response with scope + retry_after hints.
 * Shared between every /v1/* handler that enforces a rate limit — prevents
 * drift in message copy and header shape (CR2-04).
 */
export function buildRate01Response(
  scope: string,
  retryAfterSeconds: number,
  resetAt: string,
  requestId?: string,
): Response {
  const body = {
    error: ErrorCode.RATE_01,
    message: "You've hit this window's action limit. Try again shortly.",
    scope,
    retry_after_seconds: retryAfterSeconds,
    reset_at: resetAt,
  };
  const headers: Record<string, string> = {
    'content-type': 'application/json; charset=utf-8',
    'retry-after': String(retryAfterSeconds),
  };
  if (requestId) headers['x-request-id'] = requestId;
  return new Response(JSON.stringify(body), { status: 429, headers });
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
  return buildRate01Response(scopeKey, result.retry_after_seconds, result.reset_at, requestId);
}

/**
 * Best-effort source IP extraction from request headers.
 *
 * Priority:
 *   1. `x-real-ip` — Supabase's edge gateway sets this to the peer IP
 *      directly and it's NOT client-forwardable, making it the safest
 *      trusted source.
 *   2. Rightmost non-empty entry of `x-forwarded-for` — reverse proxies
 *      APPEND the peer IP to existing XFF chains, so the rightmost entry
 *      is the hop nearest the origin (the gateway's word about who's
 *      connecting). The leftmost entry is attacker-controlled and was
 *      the cause of the SA1-001/SA2-02 spoof finding; do NOT trust it.
 *   3. `cf-connecting-ip` — Cloudflare fallback (not our stack today,
 *      but harmless to keep for portability).
 *   4. `'unknown'` — all unknown-sourced callers share one bucket;
 *      aggressive on purpose.
 *
 * ASSUMPTION: Supabase edge runtime sets `x-real-ip`. If a future
 * infrastructure change breaks this, the rightmost-XFF fallback still
 * holds against client-header spoofing so long as at least one trusted
 * hop (Kong) sits in front of our functions.
 */
export function extractSourceIP(req: Request): string {
  const realIp = req.headers.get('x-real-ip');
  if (realIp) {
    const trimmed = realIp.trim();
    if (trimmed) return trimmed;
  }
  const xff = req.headers.get('x-forwarded-for');
  if (xff) {
    const parts = xff.split(',').map((p) => p.trim()).filter(Boolean);
    const rightmost = parts[parts.length - 1];
    if (rightmost) return rightmost;
  }
  const cf = req.headers.get('cf-connecting-ip');
  if (cf) {
    const trimmed = cf.trim();
    if (trimmed) return trimmed;
  }
  return 'unknown';
}
