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

/** POST /v1/session/bootstrap — returns parsed body + status. */
export async function callBootstrap(
  body: BootstrapBody | unknown,
): Promise<HttpResult<BootstrapResponse | ErrorResponse>> {
  const response = await fetch(`${FUNCTIONS_URL}/session-bootstrap`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
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
