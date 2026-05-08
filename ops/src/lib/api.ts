// Typed fetch wrapper for POST /v1/ops/admin.
//
// Every admin action uses the same endpoint with a discriminated-union
// body: { action: 'users.list' | ..., params: {...} }. Matches the
// zod schema in Backend/supabase/functions/ops-admin/index.ts.

import { supabase, OPS_ADMIN_URL } from './supabase';

export type AdminActionName =
  | 'users.list'
  | 'users.detail'
  | 'users.reset_quota'
  | 'users.status'
  | 'users.force_reauth'
  | 'flagged_outputs.list'
  | 'flagged_outputs.resolve'
  | 'cost_anomalies.list'
  | 'voice_sessions.list'
  | 'prompt_versions.rollout'
  | 'feature_flags.update'
  | 'deletion_requests.list'
  | 'deletion_requests.approve';

export class AdminApiError extends Error {
  constructor(
    public code: string,
    public httpStatus: number,
    public reason?: string,
    message?: string,
  ) {
    super(message ?? `${code} (${httpStatus})`);
    this.name = 'AdminApiError';
  }
}

async function send(session: { access_token: string }, action: AdminActionName, params: unknown): Promise<Response> {
  return await fetch(OPS_ADMIN_URL, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'authorization': `Bearer ${session.access_token}`,
      'x-request-id': (crypto.randomUUID?.() ?? Date.now().toString(16)),
    },
    body: JSON.stringify({ action, params }),
  });
}

export async function callAdmin<T>(action: AdminActionName, params: unknown): Promise<T> {
  let { data: { session } } = await supabase.auth.getSession();
  if (!session) throw new AdminApiError('AUTH-01', 401, 'missing', 'not signed in');

  let res = await send(session, action, params);

  // W43 (DB1 #16): silent refresh on a single 401. getSession() returns
  // the cached session; @supabase/supabase-js auto-refreshes on a timer
  // but not on-demand. A token seconds-from-expiry → 401 → the old flow
  // immediately surfaced AdminApiError. Try a single refresh + retry
  // before giving up.
  if (res.status === 401) {
    const { data: refreshed } = await supabase.auth.refreshSession();
    if (refreshed.session) {
      session = refreshed.session;
      res = await send(session, action, params);
    }
  }

  if (!res.ok) {
    const body = await res.json().catch(() => ({ error: 'NET-01', message: 'no body' }));
    throw new AdminApiError(
      String(body.error ?? 'NET-01'),
      res.status,
      typeof body.reason === 'string' ? body.reason : undefined,
      typeof body.message === 'string' ? body.message : undefined,
    );
  }
  return await res.json() as T;
}
