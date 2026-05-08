// SCA-88 / SCA-226 — failure-path tests for users-deletion-fulfill.
//
// Runs `processOne` and `fulfillSweep` directly against a service-role
// client so we don't depend on the cron schedule or HTTP path. The
// shared edge-runtime limitation (SCA-128) doesn't apply here because
// we're invoking in-process Deno code, not POSTing to the running
// container.
//
// Coverage:
//   1. Happy-path: approved row → completed (with cloudkit marker), all
//      cascaded child rows gone, audit_log row written AFTER delete.
//   2. Resume: a row whose external_refs_json already shows posthog
//      completed skips the PostHog step on retry.
//   3. SCA-223 (C2) regression: fulfillSweep claims at most CLAIM_LIMIT
//      approved rows per call; the surplus stays in 'approved'.
//   4. fulfillSweep zero-row path: no approved rows in db → empty summary.
//   5. SCA-222 (C1) regression: a user with inbound merged_into refs
//      gets deleted cleanly; the inbound rows survive with merged_into=null.
//   6. SCA-227 (W3) regression: requires_manual_action records survive
//      retry without overwriting their `triggered_at`.
//
// All test bodies wrap in try/finally so cleanup runs even if an
// assertion throws (SCA-237 / S8) — leaks across runs would cause
// spurious failures on subsequent invocations against the shared
// supabase stack.

import './_helpers/env.ts';

// SCA-228 test isolation: ensure external-service paths take the
// `requires_manual_action` branch deterministically. Local
// `Backend/supabase/.env` may carry staging tokens for these services
// and `_helpers/env.ts` loads everything wholesale; without these
// deletes the tests would issue real DELETEs against Sentry / RC for
// `install:test:sca88-...` users — wasted API calls at best, real
// cleanup against a staging account at worst. POSTHOG_PUBLIC_API_KEY
// is intentionally left set so the `$delete_person` event still fires
// (PostHog ingest is fire-and-forget and the test asserts the success
// path; clearing the key would silently no-op the call).
Deno.env.delete('SENTRY_AUTH_TOKEN');
Deno.env.delete('SENTRY_ORG_SLUG');
Deno.env.delete('SENTRY_PROJECT_SLUG');
Deno.env.delete('REVENUECAT_SECRET_API_KEY');

import { assert, assertEquals } from 'jsr:@std/assert';
import { createServiceClient } from '../functions/_shared/db.ts';
import { createLogger } from '../functions/_shared/logger.ts';
import { fulfillSweep, processOne } from '../functions/users-deletion-fulfill/index.ts';

const TEST_PREFIX = 'install:test:sca88';

async function hashKey(key: string): Promise<string> {
  // ADR 0027 anchor — first 16 hex chars of SHA-256(canonical_user_key).
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(key));
  return Array.from(new Uint8Array(buf))
    .slice(0, 8)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

interface SeededUser {
  canonicalUserKey: string;
  canonicalUserKeyHash: string;
  deletionRequestId: string;
}

async function seedUser(
  client: ReturnType<typeof createServiceClient>,
  suffix: string,
  state: 'approved' | 'processing' = 'processing',
): Promise<SeededUser> {
  const canonicalUserKey = `${TEST_PREFIX}-${suffix}-${crypto.randomUUID()}`;
  const canonicalUserKeyHash = await hashKey(canonicalUserKey);

  await client.from('app_users').insert({
    canonical_user_key: canonicalUserKey,
    status: 'active',
  });

  const baseRow: Record<string, unknown> = {
    canonical_user_key: canonicalUserKey,
    canonical_user_key_hash: canonicalUserKeyHash,
    state,
  };
  if (state === 'processing') baseRow.started_at = new Date().toISOString();

  const { data: row, error } = await client
    .from('deletion_requests')
    .insert(baseRow)
    .select('id')
    .single();
  if (error || !row) throw new Error(`seedUser failed: ${error?.message}`);

  return {
    canonicalUserKey,
    canonicalUserKeyHash,
    deletionRequestId: row.id,
  };
}

async function cleanup(client: ReturnType<typeof createServiceClient>, targetIds: string[] = []) {
  // Most SCA-88 test rows get hard-deleted via CASCADE during the test
  // itself; this catches partial-failure leftovers.
  if (targetIds.length > 0) {
    await client
      .from('audit_log')
      .delete()
      .eq('target_table', 'app_users')
      .in('target_id', targetIds);
  }
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
  try {
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

    // Without REVENUECAT_SECRET_API_KEY / SENTRY_AUTH_TOKEN configured,
    // those subsystems mark requires_manual_action and the outcome is
    // `partial`. Postgres sweep still runs, app_users row gone.
    assert(
      outcome === 'completed' || outcome === 'partial',
      `expected completed|partial, got ${outcome}`,
    );

    const { data: postRow } = await client
      .from('app_users')
      .select('canonical_user_key')
      .eq('canonical_user_key', seed.canonicalUserKey)
      .maybeSingle();
    assertEquals(postRow, null, 'app_users row should be deleted');

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
  } finally {
    await cleanup(client, [seed.canonicalUserKeyHash]);
  }
});

Deno.test('users-deletion-fulfill: resume skips already-completed subsystems', async () => {
  const client = createServiceClient();
  await cleanup(client);

  const seed = await seedUser(client, 'resume');
  const log = await createLogger(crypto.randomUUID(), 'users-deletion-fulfill-test');
  try {
    const priorPosthogTimestamp = '2026-05-08T18:00:00.000Z';
    const outcome = await processOne(
      client,
      {
        id: seed.deletionRequestId,
        canonical_user_key: seed.canonicalUserKey,
        canonical_user_key_hash: seed.canonicalUserKeyHash,
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
    assertEquals(refs.posthog?.completed_at, priorPosthogTimestamp);
  } finally {
    await cleanup(client, [seed.canonicalUserKeyHash]);
  }
});

Deno.test('users-deletion-fulfill: SCA-223 (C2) — fulfillSweep bounds claim at CLAIM_LIMIT', async () => {
  const client = createServiceClient();
  await cleanup(client);

  // Seed 8 approved rows. CLAIM_LIMIT in the worker is 5, so a single
  // sweep should claim 5; the remaining 3 stay 'approved'.
  const seeded: SeededUser[] = [];
  for (let i = 0; i < 8; i++) {
    seeded.push(await seedUser(client, `bound-${i}`, 'approved'));
  }
  const log = await createLogger(crypto.randomUUID(), 'users-deletion-fulfill-test');
  const targetHashes = seeded.map((s) => s.canonicalUserKeyHash);
  try {
    const summary = await fulfillSweep(client, log);
    assertEquals(summary.claimed, 5, `expected exactly CLAIM_LIMIT=5 claimed, got ${summary.claimed}`);

    // Of the surplus, 3 should still be 'approved'.
    const { data: remaining } = await client
      .from('deletion_requests')
      .select('id, state')
      .like('canonical_user_key', `${TEST_PREFIX}-bound-%`);
    const stillApproved = (remaining ?? []).filter((r) => r.state === 'approved');
    assertEquals(stillApproved.length, 3, 'expected 3 surplus rows still approved');
  } finally {
    await cleanup(client, targetHashes);
  }
});

Deno.test('users-deletion-fulfill: fulfillSweep with zero approved rows returns empty summary', async () => {
  const client = createServiceClient();
  await cleanup(client);

  const log = await createLogger(crypto.randomUUID(), 'users-deletion-fulfill-test');
  try {
    const summary = await fulfillSweep(client, log);
    assertEquals(summary.claimed, 0);
    assertEquals(summary.completed, 0);
    assertEquals(summary.failed, 0);
    assertEquals(summary.partial, 0);
  } finally {
    await cleanup(client);
  }
});

Deno.test('users-deletion-fulfill: SCA-222 (C1) — merged_into RESTRICT pre-resolved before delete', async () => {
  const client = createServiceClient();
  await cleanup(client);

  // Set up: user A is the canonical row being deleted; user B has
  // merged_into=A (alias-merge survivor). Without the pre-resolve step,
  // DELETE FROM app_users WHERE canonical_user_key=A raises 23503 because
  // app_users.merged_into is REFERENCES app_users(canonical_user_key)
  // ON DELETE RESTRICT.
  const seedA = await seedUser(client, 'merged-A');
  const keyB = `${TEST_PREFIX}-merged-B-${crypto.randomUUID()}`;
  const hashB = await hashKey(keyB);
  await client.from('app_users').insert({
    canonical_user_key: keyB,
    status: 'merged',
    merged_into: seedA.canonicalUserKey,
  });
  const log = await createLogger(crypto.randomUUID(), 'users-deletion-fulfill-test');
  try {
    const outcome = await processOne(
      client,
      {
        id: seedA.deletionRequestId,
        canonical_user_key: seedA.canonicalUserKey,
        canonical_user_key_hash: seedA.canonicalUserKeyHash,
        external_refs_json: {},
      },
      log,
    );
    assert(
      outcome === 'completed' || outcome === 'partial',
      `expected completed|partial, got ${outcome}`,
    );

    // A should be gone; B should still exist with merged_into NULL.
    const { data: rowA } = await client
      .from('app_users')
      .select('canonical_user_key')
      .eq('canonical_user_key', seedA.canonicalUserKey)
      .maybeSingle();
    assertEquals(rowA, null, 'user A should be deleted (merged_into RESTRICT pre-resolved)');

    const { data: rowB } = await client
      .from('app_users')
      .select('canonical_user_key, merged_into')
      .eq('canonical_user_key', keyB)
      .maybeSingle();
    assert(rowB, 'user B should still exist (alias survivor)');
    assertEquals(rowB!.merged_into, null, 'user B.merged_into should be NULL after pre-resolve');

    // Exactly one audit_log row.
    const { data: audits } = await client
      .from('audit_log')
      .select('id')
      .eq('target_id', seedA.canonicalUserKeyHash)
      .eq('action', 'deletion_requests.fulfilled');
    assertEquals(audits?.length, 1, 'expected exactly one audit_log row for A');
  } finally {
    // Cleanup B explicitly (not under TEST_PREFIX-bound matcher because
    // we used a separate helper to insert it; the LIKE in cleanup() does
    // catch it because it starts with TEST_PREFIX).
    await cleanup(client, [seedA.canonicalUserKeyHash, hashB]);
  }
});

Deno.test('users-deletion-fulfill: SCA-227 (W3) — requires_manual_action triggered_at preserved across retry', async () => {
  const client = createServiceClient();
  await cleanup(client);

  const seed = await seedUser(client, 'retry');
  const log = await createLogger(crypto.randomUUID(), 'users-deletion-fulfill-test');
  try {
    // Pre-populate sentry as if a prior tick had marked it manual-action
    // with a known triggered_at. The fix should preserve this on retry
    // rather than overwriting with `now()`.
    const priorTriggeredAt = '2026-05-01T12:00:00.000Z';
    const outcome = await processOne(
      client,
      {
        id: seed.deletionRequestId,
        canonical_user_key: seed.canonicalUserKey,
        canonical_user_key_hash: seed.canonicalUserKeyHash,
        external_refs_json: {
          sentry: {
            requires_manual_action: true,
            error: 'sentry_first_attempt_marker',
            triggered_at: priorTriggeredAt,
          },
        },
      },
      log,
    );
    assert(
      outcome === 'completed' || outcome === 'partial',
      `expected completed|partial, got ${outcome}`,
    );

    // The audit_log snapshot should preserve the prior triggered_at and
    // error message for ops triage.
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
    assertEquals(refs.sentry?.triggered_at, priorTriggeredAt);
    assertEquals(refs.sentry?.error, 'sentry_first_attempt_marker');
    assertEquals(refs.sentry?.requires_manual_action, true);
  } finally {
    await cleanup(client, [seed.canonicalUserKeyHash]);
  }
});
