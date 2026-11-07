import { assertEquals } from '@std/assert';
import type { createServiceClient } from '../functions/_shared/db.ts';
import type { Logger } from '../functions/_shared/logger.ts';

// Import the existing worker without starting an HTTP listener or reading any
// local .env file. All database calls below are an in-memory fluent stub.
const serve = Deno.serve;
const environment = ['SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY'].map((key) =>
  [key, Deno.env.get(key)] as const
);
let worker: typeof import('../functions/users-deletion-fulfill/index.ts');
try {
  Deno.env.set('SUPABASE_URL', 'http://127.0.0.1:54321');
  Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'unit-test-unused-key');
  Deno.serve = (() => ({})) as unknown as typeof Deno.serve;
  worker = await import('../functions/users-deletion-fulfill/index.ts');
} finally {
  Deno.serve = serve;
  for (const [key, value] of environment) {
    if (value === undefined) Deno.env.delete(key);
    else Deno.env.set(key, value);
  }
}

const log: Logger = { info() {}, warn() {}, error() {}, debug() {} };
const rowId = '00000000-0000-0000-0000-000000000001';

function fixture(failPendingWrite = false, failFinalWrite = false) {
  const calls: string[] = [];
  let pending: Record<string, unknown> | undefined;
  const client = {
    from(table: string) {
      return {
        upsert(value: Record<string, unknown>, options: unknown) {
          calls.push('pending');
          assertEquals(options, { onConflict: 'id', ignoreDuplicates: true });
          if (!failPendingWrite) pending = value;
          return Promise.resolve({ error: failPendingWrite ? { message: 'unavailable' } : null });
        },
        update() {
          return {
            eq() {
              calls.push('clear_alias');
              return Promise.resolve({ error: null });
            },
          };
        },
        delete() {
          return {
            eq() {
              calls.push('delete_' + table);
              return Promise.resolve({ error: null });
            },
          };
        },
        insert() {
          calls.push('fulfilled');
          return Promise.resolve({ error: failFinalWrite ? { message: 'unavailable' } : null });
        },
      };
    },
  } as unknown as ReturnType<typeof createServiceClient>;
  const context = {
    rowId,
    canonicalUserKey: 'ck:test',
    canonicalUserKeyHash: 'test-hash',
    refs: { posthog: { requires_manual_action: true, error: 'queued_verify_completion' } },
    requestId: '00000000-0000-0000-0000-000000000002',
    log,
  };
  return { client, context, calls, pending: () => pending };
}

Deno.test('deletion actions: pending refs survive a failed post-delete audit', async () => {
  const f = fixture(false, true);
  const result = await worker.stepPostgres(f.context, f.client);
  assertEquals(f.calls, ['pending', 'clear_alias', 'delete_app_users', 'fulfilled']);
  assertEquals(f.pending()?.id, rowId);
  assertEquals(f.pending()?.action, 'deletion_requests.external_actions_pending');
  assertEquals((f.pending()?.after_json as Record<string, unknown>).external_refs, f.context.refs);
  assertEquals(typeof result.completed_at, 'string');
});

Deno.test('deletion actions: failed durable write retains the request before cascade', async () => {
  const f = fixture(true);
  const result = await worker.stepPostgres(f.context, f.client);
  assertEquals(f.calls, ['pending']);
  assertEquals(result.error, 'external_actions_record_failed');
  assertEquals(result.completed_at, undefined);
});
