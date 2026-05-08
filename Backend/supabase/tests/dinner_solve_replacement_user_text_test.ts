// dinner_solve_replacement_user_text_test
//
// SCA-150 — pin the regenerator userText shape produced by
// `buildReplacementUserText`:
//   - non-allergen violations don't get the botanical clause
//   - nut/tree_nut/peanut allergen violations DO get the clause
//   - allergens outside the botanical-safe table (soy, shellfish) don't
//   - duplicate allergen values across multiple violations emit ONE clause
//
// Pure / I/O-free — no supabase start required.

// Load .env before module-eval — dinner-solve/index.ts transitively
// imports `_shared/db.ts`, which reads SUPABASE_URL at module load.
import './_helpers/env.ts';
import { assert, assertEquals, assertStringIncludes } from '@std/assert';
import { buildReplacementUserText } from '../functions/dinner-solve/index.ts';
import type { ValidationIssue } from '../functions/_shared/hard_rules.ts';

const BOTANICAL_MARKER = 'Botanical safety note';

Deno.test('non-allergen violations: no botanical clause', () => {
  const violations: ValidationIssue[] = [
    { kind: 'time_over_budget', actual: 50, max: 30 },
  ];
  const text = buildReplacementUserText(2, violations);
  assertStringIncludes(text, 'rank 2');
  assertStringIncludes(text, 'time_over_budget');
  assert(!text.includes(BOTANICAL_MARKER), 'time-over-budget violations should not surface the botanical note');
});

Deno.test('nut allergen: appends the botanical clause', () => {
  const violations: ValidationIssue[] = [
    { kind: 'allergen', value: 'nut', ingredient: 'almonds' },
  ];
  const text = buildReplacementUserText(1, violations);
  assertStringIncludes(text, BOTANICAL_MARKER);
  // Pin the load-bearing botanically-safe names so a typo / paraphrase
  // shows up in CI rather than silently regressing.
  assertStringIncludes(text, '"coconut"');
  assertStringIncludes(text, '"butternut squash"');
  assertStringIncludes(text, '"nutmeg"');
  // Pine nut warning must remain — it's the only seed in the safe list
  // that's still cross-reactive enough to treat as a nut. Capitalized
  // because it leads the second sentence in the constant.
  assertStringIncludes(text, '"Pine nut"');
  // The clause only fires AFTER the standard replacement instructions —
  // pin order so the model never sees the safety note in isolation.
  const violationsIdx = text.indexOf('violated hard rules');
  const noteIdx = text.indexOf(BOTANICAL_MARKER);
  assert(violationsIdx >= 0 && noteIdx > violationsIdx, 'note appears after the violation summary');
});

Deno.test('tree_nut allergen: same botanical clause as nut', () => {
  const violations: ValidationIssue[] = [
    { kind: 'allergen', value: 'tree_nut', ingredient: 'walnut' },
  ];
  const text = buildReplacementUserText(3, violations);
  assertStringIncludes(text, BOTANICAL_MARKER);
});

Deno.test('peanut allergen: same botanical clause', () => {
  const violations: ValidationIssue[] = [
    { kind: 'allergen', value: 'peanut', ingredient: 'peanut butter' },
  ];
  const text = buildReplacementUserText(1, violations);
  assertStringIncludes(text, BOTANICAL_MARKER);
});

Deno.test('non-nut allergen (soy): no botanical clause', () => {
  const violations: ValidationIssue[] = [
    { kind: 'allergen', value: 'soy', ingredient: 'edamame' },
  ];
  const text = buildReplacementUserText(2, violations);
  assertStringIncludes(text, 'edamame');
  assert(!text.includes(BOTANICAL_MARKER), 'soy allergen path doesn\'t surface the nut botanical note');
});

Deno.test('duplicate nut allergens: single clause, not stacked', () => {
  // Aggressive regenerators sometimes emit multiple ingredient
  // violations for the same allergen value (e.g. one dish with both
  // "almond flour" and "cashew cream"). The userText should emit the
  // botanical clause ONCE — duplicating it would (a) waste tokens,
  // (b) noise up the model's context, and (c) read suspicious in
  // request logs.
  const violations: ValidationIssue[] = [
    { kind: 'allergen', value: 'nut', ingredient: 'almond flour' },
    { kind: 'allergen', value: 'nut', ingredient: 'cashew cream' },
  ];
  const text = buildReplacementUserText(1, violations);
  const occurrences = text.split(BOTANICAL_MARKER).length - 1;
  assertEquals(occurrences, 1, 'botanical clause should appear exactly once even when multiple ingredients triggered the same allergen');
});

Deno.test('mixed nut + tree_nut violations: single deduped clause', () => {
  // The `nut` and `tree_nut` allergen values map to the SAME shared
  // NUT_BOTANICAL_NOTE constant in hard_rules.ts. The Set-based dedupe
  // collapses them to one clause regardless of how many distinct
  // allergen values fire.
  const violations: ValidationIssue[] = [
    { kind: 'allergen', value: 'nut', ingredient: 'pecan' },
    { kind: 'allergen', value: 'tree_nut', ingredient: 'walnut' },
  ];
  const text = buildReplacementUserText(2, violations);
  const occurrences = text.split(BOTANICAL_MARKER).length - 1;
  assertEquals(occurrences, 1);
});

Deno.test('mixed allergen + non-allergen violations: clause fires', () => {
  const violations: ValidationIssue[] = [
    { kind: 'allergen', value: 'nut', ingredient: 'pistachio' },
    { kind: 'time_over_budget', actual: 65, max: 45 },
  ];
  const text = buildReplacementUserText(2, violations);
  assertStringIncludes(text, BOTANICAL_MARKER);
  assertStringIncludes(text, 'time_over_budget');
});
