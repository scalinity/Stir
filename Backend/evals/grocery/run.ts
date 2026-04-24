// Eval harness — grocery (spec §16: 100 plans, 98% missing-item recall).
// D9 (ADR 0025): step 8 scaffolds; 100-case corpus is step 9 prereq.

import '../../supabase/tests/_helpers/env.ts';
import type { HarnessResult } from '../_shared/harness.ts';
import { gateOrSkip } from '../_shared/harness.ts';

const NAME = 'eval_grocery_v1';

export async function runHarness(): Promise<HarnessResult> {
  const skipped = gateOrSkip(NAME);
  if (skipped) return skipped;

  const started = performance.now();
  const durationMs = Math.round(performance.now() - started);

  return {
    name: NAME,
    pass: true,
    criteria: [
      { name: 'missing_item_recall', pass: true, actual: 0, threshold: 0.98, unit: 'ratio' },
    ],
    cases_total: 0,
    cases_passed: 0,
    failures: [],
    duration_ms: durationMs,
    cost_usd: 0,
    skipped: true,
    skip_reason: 'corpus build pending (step 9 prerequisite per ADR 0025)',
  };
}

if (import.meta.main) {
  const result = await runHarness();
  console.log(JSON.stringify(result, null, 2));
  if (!result.skipped && !result.pass) Deno.exit(1);
}
