import type { SupabaseClient } from '@supabase/supabase-js';
import { readCache, responseFromCache } from './idempotency.ts';
import { jsonOk } from './errors.ts';

/** Scope every read to the authenticated owner. Missing/expired content is
 * explicit; result recovery must never submit new input or debit quota. */
export async function findImportResult(
  client: SupabaseClient,
  canonicalUserKey: string,
  importID: string,
  requestID: string,
  missingIsExpired = false,
): Promise<Response | null> {
  const id = importID.toLowerCase();
  const cached = await readCache(client, canonicalUserKey, id);
  if (cached) return responseFromCache(cached, requestID);
  const { data: job, error } = await client.from('notification_jobs')
    .select('id,state,error_message,created_at')
    .eq('canonical_user_key', canonicalUserKey)
    .eq('kind', 'recipe_import_async')
    .eq('payload_json->>import_id', id)
    .order('created_at', { ascending: true }).limit(1).maybeSingle<
    { id: string; state: string; error_message: string | null; created_at: string }
  >();
  if (error) throw error;
  if (!job && !missingIsExpired) return null;
  const status = !job || job.state === 'completed' || job.error_message === 'IMPORT_EXPIRED' ||
      (['pending', 'processing'].includes(job.state) &&
        Date.parse(job.created_at) <= Date.now() - 600_000)
    ? 'expired'
    : job.state === 'failed'
    ? 'failed'
    : 'queued';
  return jsonOk(
    {
      import_id: id,
      status,
      recipe: null,
      retry_count: 0,
      prompt_version: '1.0.0',
      async_job_id: job?.id ?? null,
      ...(status === 'expired'
        ? { message: 'This import result has expired. Import the recipe again.' }
        : status === 'failed'
        ? { message: 'We could not finish this import. Try again or paste the text.' }
        : {}),
    },
    requestID,
    status === 'queued' ? 202 : 200,
  );
}
