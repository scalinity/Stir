// `pnpm run eval:all` — runs all 6 eval harnesses, aggregates results,
// emits JUnit XML + human console report. Step 8 Phase 6 / ADR 0025.
//
// Usage:
//   STIR_RUN_AI_EVALS=1 pnpm run eval:all
//   STIR_RUN_AI_EVALS=1 pnpm run eval:all --junit path/to/out.xml
//   STIR_RUN_AI_EVALS=1 pnpm run eval:all --only substitutions,cook_turns
//
// Without STIR_RUN_AI_EVALS=1 every harness reports { skipped: true } and
// total cost is $0 — safe for accidental invocation.
//
// Exit code: 0 if every non-skipped harness passes; 1 if any fails; 2 on
// infrastructure error (missing harness module, write failure).

import { runHarness as pantryScan } from './pantry_scan/run.ts';
import { runHarness as dinnerSolve } from './dinner_solve/run.ts';
import { runHarness as cookTurns } from './cook_turns/run.ts';
import { runHarness as recipeImport } from './recipe_import/run.ts';
import { runHarness as grocery } from './grocery/run.ts';
// substitutions/run.ts is from step 4 with a different shape — import later
// when we unify it with the HarnessResult contract. For now run it via
// subprocess OR skip from run_all and run `pnpm run eval:substitutions` directly.
import type { HarnessResult } from './_shared/harness.ts';
import { resultsToJUnit } from './_shared/junit.ts';
import { printReport } from './_shared/report.ts';

const HARNESSES: Record<string, () => Promise<HarnessResult>> = {
  pantry_scan:   pantryScan,
  dinner_solve:  dinnerSolve,
  cook_turns:    cookTurns,
  recipe_import: recipeImport,
  grocery:       grocery,
};
// substitutions harness is step-4 shaped and runs via `pnpm run eval:substitutions`.
// It emits its own report + exit code. Unifying to HarnessResult is tracked
// by ADR 0025 §Notes.

interface Args {
  junit?: string;
  only?: string[];
}

function parseArgs(argv: string[]): Args {
  const out: Args = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--junit' && argv[i + 1]) {
      out.junit = argv[++i];
    } else if (a === '--only' && argv[i + 1]) {
      out.only = argv[++i]!.split(',').map((s) => s.trim()).filter((s) => s.length > 0);
    }
  }
  return out;
}

const args = parseArgs(Deno.args);

const toRun = args.only ?? Object.keys(HARNESSES);
for (const name of toRun) {
  if (!(name in HARNESSES)) {
    console.error(`unknown harness: ${name}. known: ${Object.keys(HARNESSES).join(', ')}`);
    Deno.exit(2);
  }
}

const results: HarnessResult[] = [];
for (const name of toRun) {
  try {
    const result = await HARNESSES[name]!();
    results.push(result);
  } catch (err) {
    console.error(`harness ${name} threw: ${err instanceof Error ? err.message : String(err)}`);
    Deno.exit(2);
  }
}

printReport(results);

if (args.junit) {
  const xml = resultsToJUnit(results);
  await Deno.writeTextFile(args.junit, xml);
  console.log(`\nJUnit XML written to ${args.junit}`);
}

const anyFailed = results.some((r) => !r.skipped && !r.pass);
Deno.exit(anyFailed ? 1 : 0);
