// Human-readable console report for eval runs.
//
// Output:
//   eval_pantry_scan_v1                                           [SKIPPED]
//     skip: STIR_RUN_AI_EVALS=1 not set
//   eval_substitutions_v1                                         [PASS]
//     precision                                  0.95 ≥ 0.90      ✓
//     hard_rule_violations                       0    = 0          ✓
//     cases: 50/50 passed   cost: $0.0234   duration: 12.3s
//   eval_dinner_solve_v1                                          [FAIL]
//     ...

import type { HarnessResult } from './harness.ts';

const RESET = '\x1b[0m';
const DIM = '\x1b[2m';
const GREEN = '\x1b[32m';
const RED = '\x1b[31m';
const YELLOW = '\x1b[33m';

export function printReport(results: HarnessResult[]): void {
  for (const r of results) {
    const tag = r.skipped
      ? `${YELLOW}[SKIPPED]${RESET}`
      : r.pass
        ? `${GREEN}[PASS]${RESET}`
        : `${RED}[FAIL]${RESET}`;
    console.log(`${r.name.padEnd(60)} ${tag}`);
    if (r.skipped) {
      console.log(`  ${DIM}skip: ${r.skip_reason}${RESET}`);
      continue;
    }
    for (const c of r.criteria) {
      const ok = c.pass ? `${GREEN}✓${RESET}` : `${RED}✗${RESET}`;
      const actual = `${c.actual}${c.unit ? ' ' + c.unit : ''}`;
      const thr = `${c.threshold}${c.unit ? ' ' + c.unit : ''}`;
      console.log(`  ${c.name.padEnd(44)} ${actual.padStart(8)}  vs  ${thr.padEnd(8)}  ${ok}`);
    }
    const costStr = `$${r.cost_usd.toFixed(4)}`;
    console.log(
      `  ${DIM}cases: ${r.cases_passed}/${r.cases_total} passed   cost: ${costStr}   duration: ${(r.duration_ms / 1000).toFixed(1)}s${RESET}`,
    );
    if (r.failures.length > 0) {
      console.log(`  ${DIM}failures:${RESET}`);
      for (const f of r.failures.slice(0, 10)) {
        console.log(`    ${RED}×${RESET} ${f.case_name}: ${f.reason}`);
      }
      if (r.failures.length > 10) {
        console.log(`    ${DIM}... and ${r.failures.length - 10} more${RESET}`);
      }
    }
  }

  const totalPass = results.filter((r) => !r.skipped && r.pass).length;
  const totalFail = results.filter((r) => !r.skipped && !r.pass).length;
  const totalSkip = results.filter((r) => r.skipped).length;
  const totalCost = results.reduce((a, r) => a + r.cost_usd, 0);
  console.log(
    `\n${results.length} harnesses: ${GREEN}${totalPass} pass${RESET}  ${RED}${totalFail} fail${RESET}  ${YELLOW}${totalSkip} skipped${RESET}   total cost: $${totalCost.toFixed(4)}`,
  );
}
