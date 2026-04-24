-- Step-8 review W22 + W23 (+ flag_reason consistency) — storage-size CHECKs.
--
-- Zod caps the inbound shape, but these CHECKs are the last line of defense
-- against (a) a future service-role writer that bypasses the handler,
-- (b) a schema drift where the handler's Zod is loosened, (c) a direct
-- psql write during support operations.
--
-- Sizes chosen to match the handler-side Zod caps exactly:
--   - context_snapshot_json   ≤ 4 KiB serialized (matches ops-flag-output)
--   - canned_fallback_json    ≤ 64 KiB serialized (generous for recipes,
--                               cook turns, substitution result bodies)
--   - flag_reason             500 chars (tighten DB CHECK from 2000 to
--                               match the handler cap — inconsistency was
--                               flagged in SA1 S2)

BEGIN;

-- 1. context_snapshot_json — 4 KiB JSON cap.
ALTER TABLE ops_flagged_outputs
  ADD CONSTRAINT ops_flagged_outputs_context_snapshot_size_check
  CHECK (
    context_snapshot_json IS NULL
    OR pg_column_size(context_snapshot_json) <= 4096
  );

-- 2. canned_fallback_json — 64 KiB JSON cap.
ALTER TABLE ops_flagged_outputs
  ADD CONSTRAINT ops_flagged_outputs_canned_fallback_size_check
  CHECK (
    canned_fallback_json IS NULL
    OR pg_column_size(canned_fallback_json) <= 65536
  );

-- 3. flag_reason — tighten existing CHECK from 2000 to 500 chars to match
--    the handler-side Zod cap (ops-flag-output.FlagOutputRequest and the
--    max user-submitted text from iOS FlagOutputSheet).
ALTER TABLE ops_flagged_outputs
  DROP CONSTRAINT IF EXISTS ops_flagged_outputs_flag_reason_check;
ALTER TABLE ops_flagged_outputs
  ADD CONSTRAINT ops_flagged_outputs_flag_reason_check
  CHECK (length(flag_reason) <= 500);

COMMENT ON CONSTRAINT ops_flagged_outputs_context_snapshot_size_check ON ops_flagged_outputs
  IS 'Defense-in-depth 4 KiB cap. Matches Zod cap in ops-flag-output (W22 / SA1 W1).';
COMMENT ON CONSTRAINT ops_flagged_outputs_canned_fallback_size_check ON ops_flagged_outputs
  IS '64 KiB cap on canned_fallback_json — generous for any /v1/ai/* response body while bounding admin UI rendering cost (W23 / SA1 W2).';

COMMIT;
