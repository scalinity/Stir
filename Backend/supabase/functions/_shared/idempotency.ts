// Idempotency cache helpers for /v1/ai/* endpoints.
//
// Client sends a stable request_id (client_request_id / solve_request_id).
// If a non-expired cache row exists, we replay the cached response body
// verbatim — same status code, same JSON. iOS gets a byte-identical
// result whether or not the first attempt made it to Gemini.
//
// TTL: 10 minutes. Enforced by pg_cron cleanup job AND by the read
// filter here (belt-and-suspenders in case the cron missed a sweep).

import type { SupabaseClient } from '@supabase/supabase-js';

const CACHE_TTL_SECONDS = 600;

export interface CacheHit {
  response_body: unknown;
  status_code: number;
  age_seconds: number;
}

/**
 * Look up a cached response by request_id. Returns null if missing or
 * past TTL. Does NOT delete stale rows — pg_cron handles cleanup.
 */
export async function readCache(
  client: SupabaseClient,
  requestId: string,
): Promise<CacheHit | null> {
  const { data, error } = await client
    .from('ai_response_cache')
    .select('response_body, status_code, created_at')
    .eq('request_id', requestId)
    .maybeSingle<{ response_body: unknown; status_code: number; created_at: string }>();
  if (error) throw error;
  if (!data) return null;

  const createdMs = Date.parse(data.created_at);
  const ageSec = Math.floor((Date.now() - createdMs) / 1000);
  if (ageSec > CACHE_TTL_SECONDS) return null;

  return {
    response_body: data.response_body,
    status_code: data.status_code,
    age_seconds: ageSec,
  };
}

/**
 * Write a response into the cache. Fire-and-forget; failures log but
 * don't propagate. ON CONFLICT DO NOTHING because first-in wins —
 * if two concurrent requests with the same request_id both completed,
 * we already have a stable body and the second writer would only
 * overwrite with something functionally identical.
 */
export async function writeCache(
  client: SupabaseClient,
  requestId: string,
  featureKey: string,
  statusCode: number,
  responseBody: unknown,
): Promise<void> {
  const { error } = await client
    .from('ai_response_cache')
    .upsert(
      {
        request_id: requestId,
        response_body: responseBody,
        status_code: statusCode,
        feature_key: featureKey,
      },
      { onConflict: 'request_id', ignoreDuplicates: true },
    );
  if (error) {
    // Throw so the caller's try/catch can log. Don't surface to user.
    throw error;
  }
}

/**
 * Build a Response from a cache hit. Adds x-cache=hit so ops can see
 * the cache-replay rate in logs.
 */
export function responseFromCache(hit: CacheHit, requestId?: string): Response {
  const headers: Record<string, string> = {
    'content-type': 'application/json; charset=utf-8',
    'x-cache': 'hit',
    'x-cache-age-seconds': String(hit.age_seconds),
  };
  if (requestId) headers['x-request-id'] = requestId;
  return new Response(JSON.stringify(hit.response_body), {
    status: hit.status_code,
    headers,
  });
}
