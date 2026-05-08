// Phase E (telemetry wiring bundle 2026-04-24) — coverage for the
// canonical property schema (ADR 0027 / canonical-properties.md).
//
// Two surfaces this file covers:
//
// 1. Migration `20260424000007_cost_anomaly_dispatch_canonical_tags.sql`
//    — file-content snapshot for the renamed/added Sentry tags. We can't
//    assert on the actual Sentry event body because pg_net is fire-and-
//    forget and the post-dispatch wire shape isn't observable from
//    Postgres. Reading the migration file as text + asserting on the
//    jsonb_build_object key literals is a robust proxy: any future edit
//    that reintroduces `user_hash` as a tag key OR drops `system:cron`
//    breaks this test.
//
// 2. `stir_ops_force_reauth` RPC contract — Phase C amendment depends
//    on the `merged_siblings_bumped` field appearing in the RPC return.
//    This file pins that contract so a future RPC body refactor can't
//    silently drop the field (which would null out the corresponding
//    PostHog property without a typecheck failure, since the cast is
//    `result.merged_siblings_bumped as number | undefined`).
//
// === PostHog emit assertions are intentionally NOT here ===
//
// Following the pattern documented at `voice_turn_usage_test.ts:14-16`:
// posthog.ts is fire-and-forget via `EdgeRuntime.waitUntil` and asserting
// on the captured event would require either:
//   (a) a mock PostHog ingest server (binds a TCP port, intercepts
//       /i/v0/e/ POSTs, exposes a captured-events buffer to assertions);
//   (b) injecting a fake `capturePosthogEvent` via module rewrite,
//       which Deno + Supabase Edge Runtime don't support cleanly;
//   (c) a side-channel log assertion — `capturePosthogEvent` logs
//       `posthog_capture_non_2xx` / `posthog_capture_threw` on failure
//       but not on success, so success-path assertions need (a).
//
// All three options are viable but cost more test infrastructure than
// the bundle's scope. The Phase A audit (G2) and the synchronization-
// discipline rule from §10 are the working substitutes: review-time
// discipline catches drift; this test pins the wire-shape claims that
// would silently regress (RPC return contract, migration tag literals).

import './_helpers/env.ts';
import { assert, assertEquals, assertStringIncludes } from '@std/assert';
import { serviceClient } from './_helpers/pg.ts';
import { quickBootstrap } from './_helpers/factory.ts';

const MIGRATION_PATH =
  'migrations/20260424000007_cost_anomaly_dispatch_canonical_tags.sql';

// ---------------------------------------------------------------------------
// Migration 20260424000007 — Sentry tag literals
// ---------------------------------------------------------------------------

Deno.test('migration 000007: canonical_user_key_hash tag literal present', async () => {
  const sql = await Deno.readTextFile(MIGRATION_PATH);
  // The literal must appear as a jsonb_build_object key (with comma).
  // Looser `includes('canonical_user_key_hash')` would match the column
  // name in the SELECT — we want the TAG specifically.
  assertStringIncludes(sql, "'canonical_user_key_hash',");
});

Deno.test('migration 000007: actor_id system:cron tag literal present', async () => {
  const sql = await Deno.readTextFile(MIGRATION_PATH);
  assertStringIncludes(sql, "'actor_id'");
  assertStringIncludes(sql, "'system:cron'");
});

Deno.test('migration 000007: legacy user_hash NOT present as a jsonb tag key', async () => {
  const sql = await Deno.readTextFile(MIGRATION_PATH);
  // `'user_hash',` would be the syntax of a jsonb_build_object key. The
  // string CAN appear in `-- comment` lines describing the rename — the
  // assertion targets only the syntactic-key form.
  const tagKeyMatches = sql.match(/'user_hash',/g);
  assertEquals(
    tagKeyMatches,
    null,
    `migration must not introduce a 'user_hash' jsonb key (found ${tagKeyMatches?.length ?? 0})`,
  );
});

Deno.test('migration 000007: request_id NOT included as Sentry tag (cron carve-out §7.1)', async () => {
  const sql = await Deno.readTextFile(MIGRATION_PATH);
  // Per canonical-properties.md §7.1, cron-invoked surfaces omit
  // request_id FROM THE SENTRY TAG SET. Note: the function ALSO builds
  // an internal v_id_payloads jsonb for the W15 batched UPDATE which
  // carries a `'request_id'` key naming pg_net's response handle —
  // that is NOT a Sentry tag and is allowed. Scope the assertion to
  // the `'tags', jsonb_build_object(...)` block.
  const tagsBlockMatch = sql.match(/'tags',\s*jsonb_build_object\(([\s\S]*?)\)/);
  assert(
    tagsBlockMatch !== null && tagsBlockMatch[1] !== undefined,
    'tags jsonb_build_object section not found in migration',
  );
  const tagsBody = tagsBlockMatch[1];
  const tagKeyMatches = tagsBody.match(/'request_id'/g);
  assertEquals(
    tagKeyMatches,
    null,
    `cron-invoked surface must NOT add 'request_id' to Sentry tags (found ${tagKeyMatches?.length ?? 0} in tags block)`,
  );
});

// ---------------------------------------------------------------------------
// stir_ops_force_reauth RPC contract — merged_siblings_bumped
// ---------------------------------------------------------------------------

Deno.test('stir_ops_force_reauth: RPC return shape includes merged_siblings_bumped', async () => {
  const session = await quickBootstrap();
  const svc = serviceClient();

  const { data, error } = await svc.rpc('stir_ops_force_reauth', {
    p_canonical_user_key: session.canonical_user_key,
  });
  assertEquals(error, null, `RPC failed: ${error?.message ?? '<no error>'}`);

  // Phase C amendment depends on this field. Type it loosely + assert the
  // key is present + the value is a non-negative integer.
  const result = data as Record<string, unknown>;
  assertEquals(result.ok, true);
  assert('merged_siblings_bumped' in result, 'merged_siblings_bumped missing from RPC return');
  const count = result.merged_siblings_bumped as number;
  assert(typeof count === 'number', `expected number, got ${typeof count}`);
  assert(count >= 0, `expected ≥ 0, got ${count}`);

  // before + after are also part of the contract (for audit_log shape).
  assert('before' in result, 'before snapshot missing');
  assert('after' in result, 'after snapshot missing');
});

// ---------------------------------------------------------------------------
// SCA-145 — voice_quota_refund source-shape pin
// ---------------------------------------------------------------------------
//
// Per the file-header rationale (lines 22-39): PostHog emit assertions
// are intentionally not written for fire-and-forget capturePosthogEvent
// calls. Source-shape assertions are the working substitute — they
// catch wiring drift without the mock-PostHog-server infrastructure
// cost.
//
// Both refund call sites (no_active_prompt, mint_failure) must:
//   (a) call refundQuota
//   (b) emit voice_quota_refund via emitVoiceQuotaRefund
// Together they pin the SCA-145 invariant that every refund decision
// produces a disambiguating telemetry event.

const REALTIME_SESSION_PATH = 'functions/realtime-session/index.ts';

Deno.test('realtime-session: voice_quota_refund emit declared at module scope', async () => {
  const src = await Deno.readTextFile(REALTIME_SESSION_PATH);
  // Helper function exists.
  assertStringIncludes(
    src,
    'async function emitVoiceQuotaRefund(',
    'emitVoiceQuotaRefund helper must be declared',
  );
  // Event name literal — would silently regress if a refactor renamed
  // the event without updating spec §15 + CLAUDE.md.
  assertStringIncludes(
    src,
    "event: 'voice_quota_refund'",
    "voice_quota_refund event literal must appear in captureSafe call",
  );
});

Deno.test('realtime-session: voice_quota_refund actually invoked from both refund sites', async () => {
  // Sprint-B-review W3: bare assertStringIncludes on the helper name +
  // event literal would pass on commented-out code or a
  // declared-but-uncalled helper. This test counts ACTUAL `await`
  // invocations of the helper at non-declaration callsites — must
  // be exactly 2 (no_active_prompt + mint-failure). Counting matches
  // for `await emitVoiceQuotaRefund(userLog,` (note: trailing comma
  // is intentional — distinguishes the call from any comment that
  // mentions the helper name).
  const src = await Deno.readTextFile(REALTIME_SESSION_PATH);
  const callPattern = /await emitVoiceQuotaRefund\(userLog,/g;
  const matches = src.match(callPattern);
  const count = matches ? matches.length : 0;
  if (count !== 2) {
    throw new Error(
      `expected exactly 2 invocations of emitVoiceQuotaRefund(userLog, ...), got ${count}`,
    );
  }
});

Deno.test('realtime-session: voice_quota_refund emitted from no_active_prompt refund site', async () => {
  const src = await Deno.readTextFile(REALTIME_SESSION_PATH);
  // The no_active_prompt branch refunds quota AND emits the audit
  // event with reason='no_active_prompt'. Look for the discriminated
  // reason literal in proximity to the helper call.
  assertStringIncludes(
    src,
    "reason: 'no_active_prompt'",
    "no_active_prompt refund site must pass reason='no_active_prompt'",
  );
});

Deno.test('realtime-session: voice_quota_refund emitted from mint-failure refund site', async () => {
  const src = await Deno.readTextFile(REALTIME_SESSION_PATH);
  // The mint-failure catch branch discriminates on `err instanceof
  // LiveMintError`: 'mint_failed' on LiveMintError, 'mint_unexpected_error'
  // otherwise. Both literals must appear.
  assertStringIncludes(
    src,
    "'mint_failed'",
    "mint-failure refund site must pass reason='mint_failed' on LiveMintError",
  );
  assertStringIncludes(
    src,
    "'mint_unexpected_error'",
    "mint-failure refund site must pass reason='mint_unexpected_error' on non-LiveMintError",
  );
});

Deno.test('realtime-session: voice_quota_refund declares request_id + reason + upstream_status properties', async () => {
  const src = await Deno.readTextFile(REALTIME_SESSION_PATH);
  // The helper's properties shape pins the contract documented in
  // spec §15 (request_id, reason, upstream_status?). distinct_id is
  // the hashed canonical_user_key, not a property. is_refresh was
  // dropped in Sprint-B-review W6 — structurally unreachable as
  // `true` and decorative-without-alarm; do NOT re-introduce.
  assertStringIncludes(src, 'request_id: args.requestId');
  assertStringIncludes(src, 'reason: args.reason');
  assertStringIncludes(src, 'upstream_status = args.upstreamStatus');
});
