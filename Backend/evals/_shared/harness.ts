// Shared harness contract — every eval's run.ts exports `runHarness()` with
// this signature. `Backend/evals/run_all.ts` imports all 6 and aggregates.
//
// Step 8 Phase 6 / ADR 0025. Full spec-sized corpora (n=300 substitution,
// n=200 dinner_solve, etc.) are deferred per D9 — this file is the contract
// into which the expanded corpora plug when they land in step 9 prereq.

export interface HarnessCriterion {
  name: string;
  pass: boolean;
  actual: number;
  threshold: number;
  unit?: string; // e.g., 'ratio', 'count', 'ms'
}

export interface HarnessResult {
  name: string;             // e.g. 'eval_pantry_scan_v1'
  pass: boolean;            // all criteria pass
  criteria: HarnessCriterion[];
  cases_total: number;
  cases_passed: number;
  failures: Array<{ case_name: string; reason: string }>;
  duration_ms: number;
  cost_usd: number;         // total Gemini spend for the run
  skipped?: boolean;        // true when STIR_RUN_AI_EVALS=1 is unset
  skip_reason?: string;
}

export interface HarnessOptions {
  /** Hard ceiling on per-run spend. Harness exits with skip_reason if exceeded. */
  budgetUsd?: number;
  /** Cap cases run (for smoke / dev). 0 = no cap. */
  limitCases?: number;
}

export function gateOrSkip(name: string): HarnessResult | null {
  if (Deno.env.get('STIR_RUN_AI_EVALS') !== '1') {
    return {
      name,
      pass: false,
      criteria: [],
      cases_total: 0,
      cases_passed: 0,
      failures: [],
      duration_ms: 0,
      cost_usd: 0,
      skipped: true,
      skip_reason: 'STIR_RUN_AI_EVALS=1 not set — refusing to burn Gemini credits',
    };
  }
  return null;
}
