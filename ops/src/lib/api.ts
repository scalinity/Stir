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
  | 'feature_flags.update';

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

export async function callAdmin<T>(action: AdminActionName, params: unknown): Promise<T> {
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) throw new AdminApiError('AUTH-01', 401, 'missing', 'not signed in');

  const res = await fetch(OPS_ADMIN_URL, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'authorization': `Bearer ${session.access_token}`,
    },
    body: JSON.stringify({ action, params }),
  });

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
