// SCA-127 — Zod/CHECK invariant test.
//
// Three size caps on `ops_flagged_outputs` are enforced at TWO layers
// (defense-in-depth):
//
//   1. TypeScript constants in `_shared/size_caps.ts`, consumed by the
//      Zod refinements in `ops-flag-output/index.ts` (CONTEXT_SNAPSHOT_*,
//      FLAG_REASON_*) and `ops-admin/index.ts` (CANNED_FALLBACK_*).
//   2. SQL CHECK constraints on the table, defined originally in
//      `20260424000005_input_validation_size_caps.sql` and superseded
//      by any later forward-only migration that DROPs and re-ADDs the
//      same constraint name with a different cap.
//
// This test asserts the TypeScript constant value matches the most-
// recent SQL cap value for each constraint. If a handler-side change
// loosens the cap without a matching migration (or vice-versa), CI
// fails with the drifted values + the constraint name + the migration
// filename so the fix is one read away.
//
// Why parse migrations rather than query the live DB?
//   - The invariant is "TS source matches SQL source." Both ship from
//     this repo, both are version-controlled. Catching drift at file
//     level requires no Supabase stack at test time, runs in CI as a
//     pure unit test, and is robust to environments where the live DB
//     has diverged from main (e.g. staging vs prod migration lag).
//   - If a future agent adds a SECURITY DEFINER `pg_constraint` reader
//     and wants to compare live caps too, that's additive — this test
//     stays as the file-level invariant.
//
// To change a cap: see the migration-flow notes in size_caps.ts.

import { assertEquals } from '@std/assert';

import {
  CANNED_FALLBACK_MAX_BYTES,
  CONTEXT_SNAPSHOT_MAX_BYTES,
  FLAG_REASON_MAX_LEN,
} from '../functions/_shared/size_caps.ts';

interface CapInvariant {
  /** Human-readable label for assertion failure messages. */
  label: string;
  /** TypeScript-side cap (sourced from _shared/size_caps.ts). */
  tsValue: number;
  /** SQL CHECK constraint name on `ops_flagged_outputs`. */
  constraintName: string;
  /**
   * Pattern locating the numeric cap inside a constraint body. The
   * pattern uses the global flag so we can find the LAST match within
   * a constraint body via `String.matchAll(...)`. Each match's
   * group-1 is parsed via Number().
   */
  capPattern: RegExp;
}

const INVARIANTS: CapInvariant[] = [
  {
    label: 'CONTEXT_SNAPSHOT_MAX_BYTES vs context_snapshot_size_check',
    tsValue: CONTEXT_SNAPSHOT_MAX_BYTES,
    constraintName: 'ops_flagged_outputs_context_snapshot_size_check',
    // Constraint body: `pg_column_size(context_snapshot_json) <= 4096`.
    capPattern: /pg_column_size\(context_snapshot_json\)\s*<=\s*(\d+)/g,
  },
  {
    label: 'CANNED_FALLBACK_MAX_BYTES vs canned_fallback_size_check',
    tsValue: CANNED_FALLBACK_MAX_BYTES,
    constraintName: 'ops_flagged_outputs_canned_fallback_size_check',
    // Constraint body: `pg_column_size(canned_fallback_json) <= 65536`.
    capPattern: /pg_column_size\(canned_fallback_json\)\s*<=\s*(\d+)/g,
  },
  {
    label: 'FLAG_REASON_MAX_LEN vs flag_reason_check',
    tsValue: FLAG_REASON_MAX_LEN,
    constraintName: 'ops_flagged_outputs_flag_reason_check',
    // Constraint body: `length(flag_reason) <= 500`.
    capPattern: /length\(flag_reason\)\s*<=\s*(\d+)/g,
  },
];

/**
 * Walk all Backend/supabase/migrations/*.sql files in filename order
 * (which is chronological, since the convention is `YYYYMMDDHHMMSS_…`).
 * For each constraint, return the cap from the LAST migration that
 * defines (or redefines) it. A migration "defines" a constraint when
 * it contains an `ADD CONSTRAINT <name>` block whose body matches the
 * cap pattern.
 *
 * Returns `null` if no migration defines the constraint — that's a
 * different failure mode than mismatch (mismatch reports the SQL
 * value; missing reports "not defined in any migration").
 */
async function readActiveCap(
  inv: CapInvariant,
): Promise<{ value: number; migration: string } | null> {
  // Resolve the migrations directory relative to this test file so it
  // works regardless of where deno test is invoked from.
  const migrationsDir = new URL('../migrations/', import.meta.url);
  const entries: string[] = [];
  for await (const e of Deno.readDir(migrationsDir)) {
    if (e.isFile && e.name.endsWith('.sql')) {
      entries.push(e.name);
    }
  }
  entries.sort(); // YYYYMMDDHHMMSS_… → chronological by filename

  let latest: { value: number; migration: string } | null = null;
  for (const name of entries) {
    const path = new URL(name, migrationsDir);
    const sql = await Deno.readTextFile(path);
    if (!sql.includes(inv.constraintName)) continue;

    // Locate each `ADD CONSTRAINT <name> ... ;` block. Robust extraction:
    // split on `ADD CONSTRAINT <name>` and look at each subsequent slice
    // up to the next semicolon, then scan that slice for the cap.
    const splitter = new RegExp(
      `ADD\\s+CONSTRAINT\\s+${inv.constraintName}\\b`,
      'gi',
    );
    const parts = sql.split(splitter);
    // First part is everything before the first ADD; skip it.
    for (let i = 1; i < parts.length; i++) {
      const slice = parts[i];
      if (slice === undefined) continue;
      const blockEnd = slice.indexOf(';');
      const body = blockEnd >= 0 ? slice.slice(0, blockEnd) : slice;
      const matches = [...body.matchAll(inv.capPattern)];
      if (matches.length === 0) continue;
      // Take the last match in this block (handles theoretical multi-
      // CHECK bodies; current usage only ever has one cap per body).
      const last = matches[matches.length - 1];
      const captured = last?.[1];
      if (captured !== undefined) {
        latest = { value: Number(captured), migration: name };
      }
    }
  }
  return latest;
}

for (const inv of INVARIANTS) {
  Deno.test(`zod/check invariant: ${inv.label}`, async () => {
    const sqlCap = await readActiveCap(inv);
    if (sqlCap === null) {
      throw new Error(
        `[SCA-127] No migration defines CHECK constraint ` +
          `'${inv.constraintName}'. Either the constraint was renamed ` +
          `(update INVARIANTS in this file) or never landed (file the ` +
          `migration before this test will pass).`,
      );
    }

    if (sqlCap.value !== inv.tsValue) {
      throw new Error(
        `[SCA-127] Zod/CHECK drift on ${inv.label}:\n` +
          `  TypeScript value: ${inv.tsValue} ` +
          `(from Backend/supabase/functions/_shared/size_caps.ts)\n` +
          `  SQL value:        ${sqlCap.value} ` +
          `(from Backend/supabase/migrations/${sqlCap.migration})\n` +
          `  Constraint:       ${inv.constraintName}\n` +
          `\n` +
          `  Fix: bring both layers into sync. To raise the cap, update ` +
          `_shared/size_caps.ts AND add a NEW dated migration that DROPs ` +
          `and re-ADDs the constraint with the new cap. To lower, same ` +
          `flow in reverse. CLAUDE.md §Schema truth — never edit a landed ` +
          `migration in place.`,
      );
    }
    assertEquals(sqlCap.value, inv.tsValue, inv.label);
  });
}
