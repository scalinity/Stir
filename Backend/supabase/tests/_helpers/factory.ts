// Test factories + HTTP helpers for bootstrap/config-bootstrap endpoints.
//
// Conventions (plan §"Test isolation"):
//   - Every test generates fresh UUIDs (installation + CK record) so tests
//     never collide. `supabase db reset` between runs for aggregate cleanup.
//   - No teardown hooks, no transaction rollback — per-test uniqueness does
//     all isolation work.

// Side-effect import: overrides shell env with local .env values.
// See tests/_helpers/env.ts.
import './env.ts';

const FUNCTIONS_URL = Deno.env.get('SUPABASE_URL')
  ? `${Deno.env.get('SUPABASE_URL')}/functions/v1`
  : 'http://127.0.0.1:54321/functions/v1';

export function testInstallId(): string {
  return crypto.randomUUID();
}

/** Produces a CloudKit-shaped userRecordName (`_` + 32 hex). */
export function testCkRecord(): string {
  return `_${crypto.randomUUID().replaceAll('-', '').toLowerCase()}`;
}

export interface BootstrapBody {
  installation_id: string;
  cloudkit_user_record_name?: string;
  build?: string;
  os_version?: string;
}

export interface BootstrapResponse {
  session_jwt: string;
  canonical_user_key: string;
  is_new_user: boolean;
  entitlements: {
    tier: 'free' | 'premium' | 'pro';
    billing_state: string;
    is_trial: boolean;
    expires_at: string | null;
    voice_enabled: boolean;
    billing_retry_banner: boolean;
    quotas: Array<{ feature_key: string; used: number; cap: number; period_end: string }>;
  };
  feature_flags: Array<{
    key: string;
    value: unknown;
    is_enabled: boolean;
    rollout_pct: number;
  }>;
}

export interface ErrorResponse {
  error: string;
  message: string;
  [key: string]: unknown;
}

export interface HttpResult<T> {
  status: number;
  body: T;
}

/** Generate a per-test unique source IP so the bootstrap rate-limit
 * policy (ip:bootstrap_hourly 20/hr) doesn't trip across a full test
 * suite running against localhost. Tests that specifically exercise
 * the rate limiter pass their own header to override.
 */
export function testSourceIP(): string {
  // 198.51.100.0/24 is a documentation-only range (RFC 5737), safe
  // to use for synthetic test traffic.
  return `198.51.100.${Math.floor(Math.random() * 256)}`;
}

/** Standard set of IP-source headers for test requests.
 *
 * Kong in local dev unconditionally overrides `x-real-ip` to the docker
 * peer address it resolves (varies by Kong/docker version — has been a
 * private gateway historically, a public routable IP after a Kong
 * update). Because `extractSourceIP` prefers x-real-ip, tests can't
 * sidestep the rate limiter by setting x-real-ip themselves — Kong
 * will clobber it.
 *
 * Mitigation: tests instead clear the rate_limit_buckets table at the
 * top of the file (see `clearRateLimitBuckets` in pg.ts). This function
 * still sets a fresh random x-forwarded-for so tests don't collide on
 * the (now-unused for skip) XFF-rightmost fallback path and so the
 * header is present for any future extractSourceIP changes.
 */
export function testIPHeaders(): Record<string, string> {
  return {
    'x-forwarded-for': testSourceIP(),
  };
}

/** P1-B (2026-04-23): seed a row in `voice_session_owners` so a
 *  subsequent `/v1/ai/voice-turn-usage` POST passes the new IDOR
 *  ownership check. In production the mint endpoint writes this row;
 *  tests that bypass mint need to seed it explicitly. Idempotent:
 *  safe to call with a session_id that already exists (upsert).
 */
export async function seedVoiceSessionOwner(args: {
  sessionId: string;
  canonicalUserKey: string;
}): Promise<void> {
  const { serviceClient } = await import('./pg.ts');
  const client = serviceClient();
  const { error } = await client
    .from('voice_session_owners')
    .upsert(
      { session_id: args.sessionId, canonical_user_key: args.canonicalUserKey },
      { onConflict: 'session_id' },
    );
  if (error) {
    throw new Error(`seedVoiceSessionOwner failed: ${error.message}`);
  }
}

/** POST /v1/session/bootstrap — returns parsed body + status. */
export async function callBootstrap(
  body: BootstrapBody | unknown,
  headers: Record<string, string> = {},
): Promise<HttpResult<BootstrapResponse | ErrorResponse>> {
  const response = await fetch(`${FUNCTIONS_URL}/session-bootstrap`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      ...testIPHeaders(),
      ...headers,
    },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
  const parsed = await response.json();
  return { status: response.status, body: parsed };
}

/** Convenience: bootstrap with sensible defaults filled in. */
export async function quickBootstrap(
  overrides: Partial<BootstrapBody> = {},
): Promise<BootstrapResponse> {
  const body: BootstrapBody = {
    installation_id: overrides.installation_id ?? testInstallId(),
    build: overrides.build ?? '1.0.0 (1)',
    os_version: overrides.os_version ?? '17.5',
    ...(overrides.cloudkit_user_record_name !== undefined
      ? { cloudkit_user_record_name: overrides.cloudkit_user_record_name }
      : {}),
  };
  const result = await callBootstrap(body);
  if (result.status !== 200) {
    throw new Error(
      `quickBootstrap expected 200, got ${result.status}: ${JSON.stringify(result.body)}`,
    );
  }
  return result.body as BootstrapResponse;
}

/** GET /v1/config/bootstrap — returns parsed body + status. */
export async function callConfigBootstrap(
  jwt: string | null,
): Promise<HttpResult<unknown>> {
  const headers: Record<string, string> = {};
  if (jwt !== null) headers['Authorization'] = `Bearer ${jwt}`;
  const response = await fetch(`${FUNCTIONS_URL}/config-bootstrap`, {
    method: 'GET',
    headers,
  });
  const parsed = await response.json();
  return { status: response.status, body: parsed };
}
