// Size caps that are enforced at TWO layers (defense-in-depth):
//
//   1. Zod `.refine()` / `.max()` in edge handlers (ops-flag-output,
//      ops-admin) — fast-fails malformed payloads at the API edge.
//   2. SQL CHECK constraints on `ops_flagged_outputs` — last line of
//      defense against (a) future service-role writers that bypass the
//      handler, (b) handler Zod loosened in a refactor, (c) direct
//      psql writes during support operations.
//
// The two layers MUST stay synchronized. SCA-127 invariant test
// (`Backend/supabase/tests/zod_check_invariant_test.ts`) walks the
// migrations to confirm the SQL CHECK cap matches the value exported
// here; the test fails CI if a handler-side change loosens the cap
// without the matching migration (or vice-versa).
//
// To change a cap:
//   1. Update the constant below.
//   2. Add a NEW dated migration (forward-only per CLAUDE.md
//      §Schema truth — never edit a landed migration in place) that
//      DROPs and re-ADDs the matching CHECK constraint with the new
//      value. The constraint name stays stable; only the body cap
//      changes.
//   3. Run `supabase db reset` locally, then the SCA-127 invariant
//      test will pass against the new aligned values.
//
// Provenance: SCA-127 / docs/deferred-work.md line 67. Original caps
// chosen in step-8 review W22 + W23 + SA1 S2 (migration
// 20260424000005_input_validation_size_caps.sql).

/**
 * Maximum serialized JSON size for `ops_flagged_outputs.context_snapshot_json`.
 * 4 KiB is generous for the standard ops-flag-output context payload
 * (request_id, model, prompt_version, latency, error metadata) while
 * keeping the per-row storage bounded.
 *
 * SQL constraint: `ops_flagged_outputs_context_snapshot_size_check`.
 */
export const CONTEXT_SNAPSHOT_MAX_BYTES = 4096;

/**
 * Maximum serialized JSON size for `ops_flagged_outputs.canned_fallback_json`.
 * 64 KiB is generous for any /v1/ai/* response body (recipes, cook
 * turns, substitution result bodies) while bounding admin UI rendering
 * cost.
 *
 * SQL constraint: `ops_flagged_outputs_canned_fallback_size_check`.
 */
export const CANNED_FALLBACK_MAX_BYTES = 65_536;

/**
 * Maximum length (in characters) of `ops_flagged_outputs.flag_reason`.
 * 500 chars matches the iOS FlagOutputSheet's user-visible field cap;
 * the SQL CHECK was tightened from a prior 2000-char ceiling in the
 * same migration that introduced the JSON-size CHECKs (SA1 S2).
 *
 * SQL constraint: `ops_flagged_outputs_flag_reason_check`.
 */
export const FLAG_REASON_MAX_LEN = 500;
