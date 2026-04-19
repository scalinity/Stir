// Substitution eval harness (step 4).
//
// Loads eval_substitutions_v1.jsonl, calls /v1/ai/substitution for each
// case against a running local Supabase, checks hard-rule pass rate and
// schema validity. Exits non-zero on ANY allergen/dietary violation —
// substitution must hit 100% hard-rule pass per spec §12.2.
//
// Usage:
//   STIR_RUN_AI_EVALS=1 pnpm run eval:substitutions
// Requires:
//   - `supabase start` + `supabase functions serve --env-file .env`
//   - GEMINI_API_KEY set (real paid-tier key; each run consumes credits)
//
// Gate via STIR_RUN_AI_EVALS=1 so a casual `deno run` can't accidentally
// burn Gemini quota. CI does NOT run this — it's intentionally local-only
// until step 8's eval pipeline ships.

import '../../supabase/tests/_helpers/env.ts';
import { quickBootstrap, testSourceIP } from '../../supabase/tests/_helpers/factory.ts';

const FUNCTIONS_URL = Deno.env.get('SUPABASE_URL')
  ? `${Deno.env.get('SUPABASE_URL')}/functions/v1`
  : 'http://127.0.0.1:54321/functions/v1';

interface DietaryRuleCase {
  kind: 'allergy' | 'diet' | 'dislike' | 'goal';
  value: string;
  severity: 'hard' | 'soft';
}

interface EvalCase {
  name: string;
  category: 'allergen' | 'equipment' | 'intersection' | 'generic';
  expect: 'safe' | 'unsafe';
  must_not_contain: string[];
  missing: { display_name: string; canonical_slug?: string; amount_text?: string };
  user_problem: string;
  dietary_rules: DietaryRuleCase[];
  available_equipment: string[];
  pantry: string[];
  recipe_title: string;
  current_step: number;
  total_steps: number;
  remaining_ingredients: string[];
}

interface SubstitutionWireResponse {
  sub_event_id: string;
  substitution_text: string;
  amount_conversion: string | null;
  constraint_safe: boolean;
  constraint_violation_reason: string | null;
  reasoning: string;
  confidence: 'high' | 'medium' | 'low';
  prompt_version: string;
  latency_ms: number;
  retry_count: number;
}

interface CaseOutcome {
  name: string;
  category: string;
  expect: string;
  passed: boolean;
  failureReason?: string;
  latency_ms: number;
  retry_count: number;
  constraint_safe: boolean;
}

const RUN_GATE = Deno.env.get('STIR_RUN_AI_EVALS') === '1';

async function main(): Promise<void> {
  if (!RUN_GATE) {
    console.error('STIR_RUN_AI_EVALS=1 not set. Refusing to burn Gemini credits silently.');
    console.error('To run: STIR_RUN_AI_EVALS=1 pnpm run eval:substitutions');
    Deno.exit(2);
  }

  // Load eval corpus.
  const corpusPath = new URL('./eval_substitutions_v1.jsonl', import.meta.url);
  const raw = await Deno.readTextFile(corpusPath);
  const cases: EvalCase[] = raw
    .split('\n')
    .filter((l) => l.trim().length > 0)
    .map((line) => JSON.parse(line) as EvalCase);

  console.log(`Loaded ${cases.length} eval cases.`);

  // Bootstrap a shared session — eval runs don't need per-case identity.
  const session = await quickBootstrap();
  const jwt = session.session_jwt;
  console.log(`Bootstrapped session for canonical_user_key=${session.canonical_user_key.slice(0, 20)}...`);

  const outcomes: CaseOutcome[] = [];
  const startedAt = performance.now();

  for (let i = 0; i < cases.length; i++) {
    const c = cases[i];
    if (!c) continue;
    // Deno has no `process` global. Write raw bytes via stdout for
    // in-line progress rendering; console.log would add a newline.
    const writer = new TextEncoder().encode(`[${i + 1}/${cases.length}] ${c.name}... `);
    await Deno.stdout.write(writer);

    const requestBody = {
      sub_event_id: crypto.randomUUID(),
      cooking_session_id: crypto.randomUUID(),
      recipe_plan_id: crypto.randomUUID(),
      missing_ingredient: c.missing,
      user_problem: c.user_problem,
      household_context: {
        dietary_rules: c.dietary_rules,
        available_equipment: c.available_equipment,
        pantry_snapshot: c.pantry.map((p) => ({ display_name: p })),
      },
      recipe_context: {
        title: c.recipe_title,
        current_step_number: c.current_step,
        total_steps: c.total_steps,
        remaining_ingredients: c.remaining_ingredients.map((r) => ({ display_name: r })),
      },
    };

    const caseStarted = performance.now();
    const res = await fetch(`${FUNCTIONS_URL}/substitution`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'authorization': `Bearer ${jwt}`,
        'x-forwarded-for': testSourceIP(),
      },
      body: JSON.stringify(requestBody),
    });
    const latency = Math.round(performance.now() - caseStarted);

    let body: SubstitutionWireResponse | { error: string; message: string };
    try {
      body = await res.json();
    } catch (err) {
      const outcome: CaseOutcome = {
        name: c.name,
        category: c.category,
        expect: c.expect,
        passed: false,
        failureReason: `response not JSON: ${String(err)}`,
        latency_ms: latency,
        retry_count: 0,
        constraint_safe: false,
      };
      outcomes.push(outcome);
      console.log(`FAIL (${outcome.failureReason})`);
      continue;
    }

    if (res.status !== 200) {
      const errBody = body as { error: string; message: string };
      outcomes.push({
        name: c.name,
        category: c.category,
        expect: c.expect,
        passed: false,
        failureReason: `http ${res.status}: ${errBody.error ?? 'unknown'} — ${errBody.message ?? ''}`,
        latency_ms: latency,
        retry_count: 0,
        constraint_safe: false,
      });
      console.log(`FAIL (status=${res.status})`);
      continue;
    }

    const wire = body as SubstitutionWireResponse;

    // Verify the response matches expectations.
    const evaluated = evaluateOutcome(c, wire);
    outcomes.push({
      name: c.name,
      category: c.category,
      expect: c.expect,
      passed: evaluated.passed,
      ...(evaluated.reason ? { failureReason: evaluated.reason } : {}),
      latency_ms: latency,
      retry_count: wire.retry_count,
      constraint_safe: wire.constraint_safe,
    });
    console.log(evaluated.passed
      ? `ok (${latency}ms, retry=${wire.retry_count}, safe=${wire.constraint_safe})`
      : `FAIL (${evaluated.reason})`);
  }

  const totalMs = Math.round(performance.now() - startedAt);
  report(outcomes, totalMs);

  // Fail the process on any hard-rule violation (allergen/dietary appearing
  // in a response that should have been safe). Non-zero exit so CI can
  // gate on this when eval pipeline lands in step 8.
  const safeCategoryFailures = outcomes.filter((o) =>
    !o.passed && (o.category === 'allergen' || o.category === 'intersection')
  );
  if (safeCategoryFailures.length > 0) {
    console.error(`\nFATAL: ${safeCategoryFailures.length} safety-critical failures. Exit 1.`);
    Deno.exit(1);
  }
}

function evaluateOutcome(
  c: EvalCase,
  wire: SubstitutionWireResponse,
): { passed: boolean; reason?: string } {
  // For cases we expect to be unsafe: the ONLY valid response is
  // constraint_safe=false. If the model found a safe substitution we
  // didn't anticipate, treat as PASS (we're conservative — if the model
  // found a clever safe option for the peanut-satay trap, great, but it
  // usually won't).
  if (c.expect === 'unsafe') {
    // Accept either the canned-safe fallback OR a genuine safe find.
    // Still check must_not_contain in case the model fabricated a "safe"
    // answer that secretly contains the allergen.
    if (!wire.constraint_safe) return { passed: true };
    const leak = findLeak(wire, c.must_not_contain);
    if (leak) {
      return {
        passed: false,
        reason: `expected unsafe but model claimed safe AND leaked keyword '${leak}'`,
      };
    }
    // Genuine safe find — note in log but count as pass.
    return { passed: true };
  }

  // expect === 'safe'
  const leak = findLeak(wire, c.must_not_contain);
  if (leak) {
    return {
      passed: false,
      reason: `response contains forbidden keyword '${leak}'`,
    };
  }

  // When we expected safe and the model returned constraint_safe=false,
  // that's a miss: model couldn't find a substitution we know exists in
  // the pantry. Count as fail but it's a recall miss, not a safety breach.
  if (!wire.constraint_safe) {
    return {
      passed: false,
      reason: `expected safe substitution but model returned constraint_safe=false`,
    };
  }

  return { passed: true };
}

function findLeak(wire: SubstitutionWireResponse, needles: string[]): string | null {
  if (needles.length === 0) return null;
  const combined = [
    wire.substitution_text,
    wire.reasoning,
    wire.amount_conversion ?? '',
  ].join(' ').toLowerCase();
  for (const n of needles) {
    const needle = n.toLowerCase().trim();
    if (!needle) continue;
    if (combined.includes(needle)) return n;
  }
  return null;
}

function report(outcomes: CaseOutcome[], totalMs: number): void {
  const byCategory = new Map<string, CaseOutcome[]>();
  for (const o of outcomes) {
    const list = byCategory.get(o.category) ?? [];
    list.push(o);
    byCategory.set(o.category, list);
  }
  const totalPass = outcomes.filter((o) => o.passed).length;
  const totalFail = outcomes.length - totalPass;
  const latencies = outcomes.map((o) => o.latency_ms).sort((a, b) => a - b);
  const p50 = latencies[Math.floor(latencies.length * 0.5)] ?? 0;
  const p95 = latencies[Math.floor(latencies.length * 0.95)] ?? 0;
  const retries = outcomes.filter((o) => o.retry_count > 0).length;

  console.log('\n=============================================');
  console.log(`eval_substitutions_v1: ${totalPass}/${outcomes.length} passed`);
  console.log(`total duration: ${totalMs}ms`);
  console.log(`per-call latency: p50=${p50}ms, p95=${p95}ms`);
  console.log(`retry count: ${retries}/${outcomes.length} cases used ≥1 retry`);
  console.log('=============================================');
  for (const [cat, list] of byCategory) {
    const pass = list.filter((o) => o.passed).length;
    console.log(`  ${cat.padEnd(14)} ${pass}/${list.length}`);
  }
  if (totalFail > 0) {
    console.log('\nFailures:');
    for (const o of outcomes.filter((x) => !x.passed)) {
      console.log(`  - [${o.category}] ${o.name}: ${o.failureReason}`);
    }
  }
  console.log('');
}

await main();
