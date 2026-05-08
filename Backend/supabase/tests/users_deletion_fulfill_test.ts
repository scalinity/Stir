// SCA-88 — smoke tests for users-deletion-fulfill state machine.
//
// Runs `processOne` directly against a service-role client so we don't
// depend on the cron schedule or HTTP path. The shared edge-runtime
// limitation (SCA-128) doesn't apply here because we're invoking
// in-process Deno code, not POSTing to the running container.
//
// Coverage:
//   1. Happy-path: approved row → completed (with cloudkit marker), all
//      cascaded child rows gone, audit_log row written.
//   2. Resume: a row whose external_refs_json already shows posthog
//      completed skips the PostHog step on retry.
//   3. CloudKit marker: requires_client_action populated and survives in
//      the audit_log after_json snapshot.

import './_helpers/env.ts';
import { assert, assertEquals } from 'jsr:@std/assert';
import { createServiceClient } from '../functions/_shared/db.ts';
import { createLogger } from '../functions/_shared/logger.ts';
import { processOne } from '../functions/users-deletion-fulfill/index.ts';

const TEST_PREFIX = 'install:test:sca88';

async function seedUser(
  client: ReturnType<typeof createServiceClient>,
  suffix: string,
): Promise<{ canonicalUserKey: string; canonicalUserKeyHash: string; deletionRequestId: string }> {
  const canonicalUserKey = `${TEST_PREFIX}-${suffix}-${crypto.randomUUID()}`;
  // hash = first 16 hex of SHA-256(canonical_user_key) per ADR 0027
  const buf = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(canonicalUserKey),
  );
  const canonicalUserKeyHash = Array.from(new Uint8Array(buf))
    .slice(0, 8)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');

  await client.from('app_users').insert({
    canonical_user_key: canonicalUserKey,
    status: 'active',
  });

  const { data: row, error } = await client
    .from('deletion_requests')
    .insert({
      canonical_user_key: canonicalUserKey,
      canonical_user_key_hash: canonicalUserKeyHash,
      state: 'processing', // processOne expects already-claimed rows
      started_at: new Date().toISOString(),
    })
    .select('id')
    .single();
  if (error || !row) throw new Error(`seedUser failed: ${error?.message}`);

  return {
    canonicalUserKey,
    canonicalUserKeyHash,
    deletionRequestId: row.id,
  };
}

async function cleanup(client: ReturnType<typeof createServiceClient>) {
  // Most SCA-88 test rows get hard-deleted via CASCADE during the test
  // itself; this catches partial-failure leftovers.
  await client
    .from('audit_log')
    .delete()
    .eq('target_table', 'app_users')
    .like('target_id', '%');
  await client
    .from('deletion_requests')
    .delete()
    .like('canonical_user_key', `${TEST_PREFIX}%`);
  await client.from('app_users').delete().like('canonical_user_key', `${TEST_PREFIX}%`);
}

Deno.test('users-deletion-fulfill: happy-path approved → completed (with cloudkit marker)', async () => {
  const client = createServiceClient();
  await cleanup(client);

  const seed = await seedUser(client, 'happy');
  const log = await createLogger(crypto.randomUUID(), 'users-deletion-fulfill-test');

  const outcome = await processOne(
    client,
    {
      id: seed.deletionRequestId,
      canonical_user_key: seed.canonicalUserKey,
      canonical_user_key_hash: seed.canonicalUserKeyHash,
      external_refs_json: {},
    },
    log,
  );

  // Without REVENUECAT_SECRET_API_KEY / SENTRY_AUTH_TOKEN configured in
  // the test env, those subsystems mark requires_manual_action and the
  // outcome is `partial`. Postgres sweep still runs, app_users row gone.
  assert(
    outcome === 'completed' || outcome === 'partial',
    `expected completed|partial, got ${outcome}`,
  );

  // app_users row gone → CASCADE wiped deletion_requests too.
  const { data: postRow } = await client
    .from('app_users')
    .select('canonical_user_key')
    .eq('canonical_user_key', seed.canonicalUserKey)
    .maybeSingle();
  assertEquals(postRow, null, 'app_users row should be deleted');

  // audit_log row survives.
  const { data: audits } = await client
    .from('audit_log')
    .select('action, target_id, after_json')
    .eq('target_id', seed.canonicalUserKeyHash)
    .eq('action', 'deletion_requests.fulfilled');
  assertEquals(audits?.length, 1, 'expected exactly one audit_log row');
  const after = audits![0]!.after_json as Record<string, unknown>;
  const refs = after.external_refs as Record<string, Record<string, unknown>>;
  assertEquals(refs.cloudkit?.requires_client_action, true);
  assertEquals(typeof refs.cloudkit?.triggered_at, 'string');

  await cleanup(client);
});

Deno.test('users-deletion-fulfill: resume skips already-completed subsystems', async () => {
  const client = createServiceClient();
  await cleanup(client);

  const seed = await seedUser(client, 'resume');
  const log = await createLogger(crypto.randomUUID(), 'users-deletion-fulfill-test');

  const priorPosthogTimestamp = '2026-05-08T18:00:00.000Z';
  const outcome = await processOne(
    client,
    {
      id: seed.deletionRequestId,
      canonical_user_key: seed.canonicalUserKey,
      canonical_user_key_hash: seed.canonicalUserKeyHash,
      // Pre-populate as if a prior tick had succeeded for posthog.
      external_refs_json: {
        posthog: {
          completed_at: priorPosthogTimestamp,
          distinct_id_hash: seed.canonicalUserKeyHash,
        },
      },
    },
    log,
  );

  assert(
    outcome === 'completed' || outcome === 'partial',
    `expected completed|partial, got ${outcome}`,
  );

  const { data: audits } = await client
    .from('audit_log')
    .select('after_json')
    .eq('target_id', seed.canonicalUserKeyHash)
    .eq('action', 'deletion_requests.fulfilled');
  assertEquals(audits?.length, 1);
  const refs = (audits![0]!.after_json as Record<string, unknown>).external_refs as Record<
    string,
    Record<string, unknown>
  >;
  // PostHog step should have preserved the prior timestamp rather than
  // overwriting with `now()`.
  assertEquals(refs.posthog?.completed_at, priorPosthogTimestamp);

  await cleanup(client);
});
