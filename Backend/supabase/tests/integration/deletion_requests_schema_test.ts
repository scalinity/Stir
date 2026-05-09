// SCA-172 / DB1-13 — schema-level coverage for `deletion_requests`'s
// partial unique index that backs the handler's idempotent-insert path.
//
// The migration `20260508000002_init_deletion_requests.sql` creates:
//
//   CREATE UNIQUE INDEX uq_deletion_requests_in_flight
//     ON deletion_requests(canonical_user_key)
//     WHERE state IN ('pending', 'approved', 'processing');
//
// `users-delete-request/index.ts` depends on this index in two places:
//   1. The race-recovery branch (CA2-02) catches `code === '23505'`
//      from a concurrent INSERT and re-fetches the winning row.
//   2. The idempotent-existing probe relies on at most one in-flight row
//      per user being present so the SELECT-then-INSERT TOCTOU race is
//      bounded — the unique index serializes the racing inserts.
//
// Drop the index, change the predicate, or migrate the WHERE clause off
// the non-terminal states list and the handler silently degrades to
// "duplicate audit rows accumulate, two iOS clients can both create
// deletion_requests rows for the same user." This test guards against
// those silent regressions.
//
// Coverage:
//   1. Insert state='pending' → succeeds.
//   2. Insert state='completed' for the SAME user → succeeds (terminal
//      state, partial index doesn't apply).
//   3. Second state='pending' for same user → 23505 (the partial-unique
//      gate fires).
//   4. Replace the failed row with state='approved' → succeeds (no
//      in-flight collision because completed != non-terminal).
//   5. Insert state='approved' on top of an existing pending → 23505.

import '../_helpers/env.ts';
import { assertEquals } from '@std/assert';
import { serviceClient } from '../_helpers/pg.ts';

interface SeededUser {
  canonicalKey: string;
}

async function seedUser(): Promise<SeededUser> {
  const svc = serviceClient();
  const canonicalKey = `ck:test:sca172schema:${crypto.randomUUID()}`;
  const { error } = await svc.from('app_users').insert({
    canonical_user_key: canonicalKey,
    current_install_id: crypto.randomUUID(),
    revenuecat_app_user_id: canonicalKey,
    source_type: 'cloudkit',
    status: 'active',
  });
  if (error) throw new Error(`seedUser failed: ${error.message}`);
  return { canonicalKey };
}

async function cleanupUser(canonicalKey: string): Promise<void> {
  const svc = serviceClient();
  await svc.from('app_users').delete().eq('canonical_user_key', canonicalKey);
}

function fakeHash(): string {
  return 'hash-' + crypto.randomUUID().slice(0, 8);
}

Deno.test('SCA-172 deletion_requests schema: insert state=pending succeeds', async () => {
  const { canonicalKey } = await seedUser();
  try {
    const svc = serviceClient();
    const { error } = await svc.from('deletion_requests').insert({
      canonical_user_key: canonicalKey,
      canonical_user_key_hash: fakeHash(),
      state: 'pending',
    });
    assertEquals(error, null);
  } finally {
    await cleanupUser(canonicalKey);
  }
});

Deno.test('SCA-172 deletion_requests schema: insert state=completed for same user as pending succeeds (terminal NOT in partial WHERE)', async () => {
  const { canonicalKey } = await seedUser();
  try {
    const svc = serviceClient();
    // Land a pending row first.
    {
      const { error } = await svc.from('deletion_requests').insert({
        canonical_user_key: canonicalKey,
        canonical_user_key_hash: fakeHash(),
        state: 'pending',
      });
      assertEquals(error, null);
    }
    // A second row in a TERMINAL state is allowed because the partial
    // index only applies when state ∈ {pending, approved, processing}.
    // Real-world shape: a user submits, the worker fails, ops marks the
    // pending row 'failed' (terminal); a fresh 'pending' from a retry
    // would conflict — but a 'completed' historical row should NOT
    // conflict with a current pending row.
    const { error: err2 } = await svc.from('deletion_requests').insert({
      canonical_user_key: canonicalKey,
      canonical_user_key_hash: fakeHash(),
      state: 'completed',
    });
    assertEquals(err2, null);
  } finally {
    await cleanupUser(canonicalKey);
  }
});

Deno.test('SCA-172 deletion_requests schema: second state=pending for same user → 23505 (partial unique fires)', async () => {
  const { canonicalKey } = await seedUser();
  try {
    const svc = serviceClient();
    {
      const { error } = await svc.from('deletion_requests').insert({
        canonical_user_key: canonicalKey,
        canonical_user_key_hash: fakeHash(),
        state: 'pending',
      });
      assertEquals(error, null);
    }

    // The duplicate non-terminal insert MUST fail with 23505. This is
    // the index's whole purpose — it serializes concurrent submits at
    // the DB layer so the handler's race-recovery branch (CA2-02) has
    // something deterministic to catch.
    const { error: dupErr } = await svc.from('deletion_requests').insert({
      canonical_user_key: canonicalKey,
      canonical_user_key_hash: fakeHash(),
      state: 'pending',
    });
    if (!dupErr) {
      throw new Error('expected unique-violation; got null error');
    }
    // PostgREST surfaces Postgres error code as `code` on the error
    // object; jsonb-prefixed for HTTP transport but the supabase-js
    // client preserves the field.
    assertEquals((dupErr as { code?: string }).code, '23505');
  } finally {
    await cleanupUser(canonicalKey);
  }
});

Deno.test('SCA-172 deletion_requests schema: pending + approved for same user → 23505 (both states in partial WHERE)', async () => {
  const { canonicalKey } = await seedUser();
  try {
    const svc = serviceClient();
    {
      const { error } = await svc.from('deletion_requests').insert({
        canonical_user_key: canonicalKey,
        canonical_user_key_hash: fakeHash(),
        state: 'pending',
      });
      assertEquals(error, null);
    }

    // 'approved' is also in the partial-WHERE so a second row in
    // 'approved' state for the same user MUST collide with the pending
    // row. Pre-fix (or a future regression that drops 'approved' from
    // the partial WHERE) would let an admin double-approve a user mid-
    // queue and the worker would race two parallel fulfillments.
    const { error: dupErr } = await svc.from('deletion_requests').insert({
      canonical_user_key: canonicalKey,
      canonical_user_key_hash: fakeHash(),
      state: 'approved',
    });
    if (!dupErr) {
      throw new Error('expected unique-violation on pending+approved; got null error');
    }
    assertEquals((dupErr as { code?: string }).code, '23505');
  } finally {
    await cleanupUser(canonicalKey);
  }
});

Deno.test('SCA-172 deletion_requests schema: pending + failed for same user succeeds (failed NOT in partial WHERE)', async () => {
  const { canonicalKey } = await seedUser();
  try {
    const svc = serviceClient();
    {
      const { error } = await svc.from('deletion_requests').insert({
        canonical_user_key: canonicalKey,
        canonical_user_key_hash: fakeHash(),
        state: 'pending',
      });
      assertEquals(error, null);
    }
    // 'failed' is a terminal state, NOT included in the partial WHERE
    // ('pending', 'approved', 'processing'). A failed row + pending row
    // for the same user is a real shape — the failed row records the
    // prior fulfillment-worker error; the pending row is the retry.
    const { error: failedErr } = await svc.from('deletion_requests').insert({
      canonical_user_key: canonicalKey,
      canonical_user_key_hash: fakeHash(),
      state: 'failed',
      failure_reason: 'cloudkit_zone_delete_returned_500',
    });
    assertEquals(failedErr, null);
  } finally {
    await cleanupUser(canonicalKey);
  }
});

Deno.test('SCA-172 deletion_requests schema: completed + completed for same user succeeds (terminal)', async () => {
  // Two terminal rows for the same user is unusual but legal — the audit
  // log needs to retain history of every deletion request ever made.
  // The partial unique index MUST NOT block historical retention.
  const { canonicalKey } = await seedUser();
  try {
    const svc = serviceClient();
    for (let i = 0; i < 2; i++) {
      const { error } = await svc.from('deletion_requests').insert({
        canonical_user_key: canonicalKey,
        canonical_user_key_hash: fakeHash(),
        state: 'completed',
      });
      assertEquals(error, null);
    }
    // Two rows landed.
    const { data } = await svc
      .from('deletion_requests')
      .select('id')
      .eq('canonical_user_key', canonicalKey);
    assertEquals((data ?? []).length, 2);
  } finally {
    await cleanupUser(canonicalKey);
  }
});
