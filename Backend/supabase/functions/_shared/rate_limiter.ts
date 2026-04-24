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
  | 'ip:substitution_daily'
  | 'ip:cook_turn_daily'
  | 'ip:bootstrap_hourly'
  | 'ip:recipe_import_daily'
  | 'ip:grocery_generate_daily'
  | 'ip:push_register_hourly'
  | 'ip:voice_turn_usage_daily'
  | 'ip:realtime_session_daily'
  | 'ip:ops_admin_hourly'
  | 'user:dinner_solve_hourly'
  | 'user:voice_turn_usage_hourly'
  | 'user:cook_turn_hourly'
  | 'user:realtime_session_hourly';

export interface RateLimitPolicy {
  windowSeconds: number;
  maxCount: number;
}

/**
 * Hardcoded policy table. Tuned per CLAUDE.md §Deferred:
 *   - IP dinner_solve 30/day: Apple-ID rotation defense
 *   - IP pantry_parse 100/day: generous; parse is cheap and abused less
 *   - IP substitution 50/day: cheap ($0.00158/call) and often-used; burst
 *     protection only — legitimate cooking sessions won't blow this
 *   - IP bootstrap 20/hour: stops JWT-farming + synthetic install DoS
 *     without interfering with legitimate re-launches on a shared NAT
 *   - user dinner_solve 10/hour: burst protection over monthly quota
 */
export const RATE_LIMIT_POLICIES: Readonly<Record<RateLimitPolicyKey, RateLimitPolicy>> = {
  'ip:dinner_solve_daily':    { windowSeconds: 86400, maxCount: 30 },
  'ip:pantry_parse_daily':    { windowSeconds: 86400, maxCount: 100 },
  'ip:substitution_daily':    { windowSeconds: 86400, maxCount: 50 },
  'ip:cook_turn_daily':       { windowSeconds: 86400, maxCount: 300 },
  'ip:bootstrap_hourly':      { windowSeconds: 3600,  maxCount: 20 },
  // Step 7 additions:
  // recipe_import: unmetered per-user quota (Free:2/mo, Premium/Pro:unlimited)
  //   enforced separately via usage_counters. This IP cap catches abusers
  //   who rotate Apple IDs; 40/day covers 20 imports × 2 retries.
  'ip:recipe_import_daily':    { windowSeconds: 86400, maxCount: 40 },
  // grocery_generate: unmetered across all tiers; 100/day/IP is a burst cap,
  //   not a product cap. A real user generates <5/day.
  'ip:grocery_generate_daily': { windowSeconds: 86400, maxCount: 100 },
  // push_register: iOS calls once per install + once per preference change.
  //   20/hour prevents token-churn abuse (rotating installs to enumerate
  //   apns_token space) without interfering with legitimate use.
  'ip:push_register_hourly':   { windowSeconds: 3600,  maxCount: 20 },
  'user:dinner_solve_hourly': { windowSeconds: 3600,  maxCount: 10 },
  // voice_turn_usage (ADR 0009): one POST per Gemini Live turnComplete.
  // A realistic Premium voice session emits ~15 POSTs; the 500/hr user
  // cap allows ~33 sessions/hr (far above the 20 voice_cook_session
  // monthly quota). The IP cap (2000/day) is defense against forged
  // clients trying to inflate ai_request_log + PostHog ingest volume;
  // real households aren't voice-cooking all day.
  'ip:voice_turn_usage_daily':   { windowSeconds: 86400, maxCount: 2000 },
  'user:voice_turn_usage_hourly':{ windowSeconds: 3600,  maxCount: 500 },
  // Cook turn (text fallback when Gemini Live is unavailable) is
  // Premium+ tier-gated but NOT metered via usage_counters — spec §9
  // calls the fallback path "unmetered" because a healthy user on
  // the Live path never hits it. But a user stuck on the C.3 fallback
  // (kill switch engaged, or chronic mint failures on their account)
  // could call /v1/ai/cook-turn indefinitely up to the 300/day IP cap.
  // 300 × $0.0023/call = ~$0.69/day/user — breaks the Premium $1.89/mo
  // AI budget. 30/hour/user is generous (covers a 15-turn cook session
  // with 2x headroom for repeats) while clamping the worst-case cost
  // exposure at ~$0.05/hour = ~$1.20/day/user in the persistent-C.3
  // scenario. Revisit if real C.3 users regularly hit the cap.
  'user:cook_turn_hourly':       { windowSeconds: 3600,  maxCount: 30 },
  // realtime_session (ADR 0014): each mint opens a Gemini Live session.
  // Normal path: 1 mint per Cook Mode entry + 1 refresh per ~10 turns.
  // A Premium user's 20 voice_cook_session monthly cap, even with 3
  // refreshes per session, is 80 mints/month = ~2.7/day. IP 200/day
  // is a generous burst cap that catches a runaway-refresh bug on the
  // client (or a malicious client looping is_refresh=true to bypass
  // quota) without interfering with shared-NAT households. User cap
  // 40/hour protects a single account from a 1000-mints/hour script.
  'ip:realtime_session_daily':    { windowSeconds: 86400, maxCount: 200 },
  'user:realtime_session_hourly': { windowSeconds: 3600,  maxCount: 40 },
  // ops_admin (SA2 W2): admin-token compromise → unbounded enumeration via
  // users.list / flagged_outputs.list. 30/min = 1800/hour per IP caps an
  // attacker at 30 rpm — enough headroom for legit active triage (rarely
  // exceeds 5-10 rpm) while cutting enumeration from thousands/sec to
  // 30/min. Per-admin bucket is a step-9 follow-up per CLAUDE.md §Deferred.
  'ip:ops_admin_hourly':          { windowSeconds: 3600,  maxCount: 1800 },
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

/**
 * Privacy-grade bucket identifier for a source IP. HMAC-SHA256 keyed on
 * a rotated env-sourced salt (`LOG_IP_SALT`), truncated to 16 hex chars
 * (64 bits — plenty for dashboard-dedup collision resistance at our
 * scale). Same IP + same salt always produce the same bucket within a
 * salt-rotation window; a new salt invalidates all prior buckets and
 * prevents log-access-based IP reversal attacks.
 *
 * **Fallback:** If `LOG_IP_SALT` is absent (missing secret in prod, or
 * test env without one), falls back to an unsalted FNV-1a bucket
 * prefixed `unsalted:`. The prefix is deliberately observable — the
 * prefix shows up in logs/dashboards as a misconfig signal, not silent
 * degradation. Setting the secret AFTER deploys already have unsalted
 * buckets in the log window is fine; new requests start producing
 * salted buckets immediately. Dashboards that query by bucket prefix
 * (`ip_*` vs `unsalted:*`) can filter.
 *
 * **Threat model:** protects against an attacker with log-read access
 * reversing buckets back to raw IPs. Does NOT protect against an
 * attacker who can read both logs AND the salt (at that point they
 * can re-derive by brute-forcing ~4B IPv4 candidates in O(seconds)).
 * Rotate monthly per `docs/runbooks/ip-salt-rotation.md`.
 *
 * Async because WebCrypto's HMAC is async. Only one caller pre-step-9
 * (`realtime-session/index.ts:source_ip_bucket`) — caller is already
 * inside an async handler, so adding `await` is free.
 *
 * P2-C (2026-04-23 filed; 2026-04-24 shipped).
 */
export async function ipBucket(ip: string): Promise<string> {
  if (ip === 'unknown' || ip === '') return 'unknown';

  const salt = Deno.env.get('LOG_IP_SALT');
  if (!salt) {
    // FNV-1a fallback with observability-friendly prefix. Emits a one-
    // shot stderr warning per process so misconfig is noisy but doesn't
    // spam at request rate.
    warnOnceLogIpSaltMissing();
    return 'unsalted:' + fnv1aHex(ip);
  }

  try {
    const key = await crypto.subtle.importKey(
      'raw',
      new TextEncoder().encode(salt),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign'],
    );
    const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(ip));
    const bytes = new Uint8Array(sig);
    let hex = '';
    for (let i = 0; i < 8; i++) hex += bytes[i]!.toString(16).padStart(2, '0');
    return 'ip_' + hex;
  } catch (e) {
    // WebCrypto failure (malformed salt, unsupported algorithm) falls
    // back to the unsalted bucket rather than throwing through the
    // rate-limit path. Observable via the same prefix.
    console.warn('[rate_limiter] HMAC bucket fallback: ' + (e instanceof Error ? e.message : String(e)));
    return 'unsalted:' + fnv1aHex(ip);
  }
}

let _logIpSaltWarned = false;
function warnOnceLogIpSaltMissing(): void {
  if (_logIpSaltWarned) return;
  _logIpSaltWarned = true;
  console.warn('[rate_limiter] LOG_IP_SALT not set; using unsalted FNV-1a bucket (privacy-degraded path). Set LOG_IP_SALT via `supabase secrets set LOG_IP_SALT=$(openssl rand -hex 32)` — see docs/runbooks/ip-salt-rotation.md.');
}

function fnv1aHex(ip: string): string {
  let hash = 0x811c9dc5;
  for (let i = 0; i < ip.length; i++) {
    hash ^= ip.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, '0');
}
