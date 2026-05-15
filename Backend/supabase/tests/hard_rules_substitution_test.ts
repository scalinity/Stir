// Unit tests for validateSubstitution (step 4).
//
// Exercises the hard-rule validator on free-form suggestion text:
// allergen plain-substring match, diet word-boundary match, equipment
// substring match, claims_pass_falsely, and summarizeViolations output.

import { assertEquals } from '@std/assert';
import {
  type DietaryRule,
  summarizeViolations,
  validateSubstitution,
} from '../functions/_shared/hard_rules.ts';

function allergy(value: string): DietaryRule {
  return { kind: 'allergy', value, severity: 'hard' };
}

function diet(value: string): DietaryRule {
  return { kind: 'diet', value, severity: 'hard' };
}

function dislike(value: string): DietaryRule {
  return { kind: 'dislike', value, severity: 'hard' };
}

Deno.test('validateSubstitution: clean suggestion passes', () => {
  const result = validateSubstitution(
    {
      substitution_text: 'Use olive oil instead',
      reasoning: 'Nearly identical flavor profile',
      constraint_safe: true,
    },
    {
      dietaryRules: [allergy('peanut')],
      availableEquipment: ['stovetop', 'skillet'],
    },
  );
  assertEquals(result.valid, true);
  assertEquals(result.issues.length, 0);
});

Deno.test('validateSubstitution: allergen substring triggers violation', () => {
  const result = validateSubstitution(
    {
      substitution_text: 'Use peanut oil instead',
      reasoning: 'Similar smoke point',
      constraint_safe: true,
    },
    {
      dietaryRules: [allergy('peanut')],
      availableEquipment: ['stovetop'],
    },
  );
  assertEquals(result.valid, false);
  assertEquals(result.issues.some((i) => i.kind === 'allergen'), true);
  // Model claimed safe but we caught it — claims_pass_falsely triggers.
  assertEquals(result.issues.some((i) => i.kind === 'claims_pass_falsely'), true);
});

Deno.test('validateSubstitution: dairy diet catches milk in text', () => {
  const result = validateSubstitution(
    {
      substitution_text: 'Use whole milk as a substitute',
      reasoning: 'Close match',
      constraint_safe: false,
    },
    {
      dietaryRules: [diet('dairy-free')],
      availableEquipment: ['stovetop'],
    },
  );
  assertEquals(result.valid, false);
  assertEquals(result.issues.some((i) => i.kind === 'diet_violation'), true);
  // Model self-reported constraint_safe=false, so claims_pass_falsely
  // should NOT be added (model was honest).
  assertEquals(result.issues.some((i) => i.kind === 'claims_pass_falsely'), false);
});

Deno.test('validateSubstitution: gluten diet does NOT false-positive on buckwheat', () => {
  // 'wheat' substring appears in 'buckwheat' but the word-boundary
  // diet matcher should reject the partial match.
  const result = validateSubstitution(
    {
      substitution_text: 'Use buckwheat flour instead',
      reasoning: 'Naturally gluten-free grain substitute',
      constraint_safe: true,
    },
    {
      dietaryRules: [diet('gluten-free')],
      availableEquipment: ['oven', 'mixing bowl'],
    },
  );
  assertEquals(result.valid, true);
});

Deno.test('validateSubstitution: allergen still matches even on compound words (safety bias)', () => {
  // Allergy uses plain-substring: "eggplant" contains "egg" → violates
  // egg allergy. Safety-first: better to retry than ship an allergen.
  const result = validateSubstitution(
    {
      substitution_text: 'Try eggplant as the base',
      reasoning: 'Neutral flavor',
      constraint_safe: true,
    },
    {
      dietaryRules: [allergy('egg')],
      availableEquipment: ['oven'],
    },
  );
  assertEquals(result.valid, false);
  assertEquals(result.issues.some((i) => i.kind === 'allergen'), true);
});

Deno.test('validateSubstitution: dislike rules match plain substring', () => {
  const result = validateSubstitution(
    {
      substitution_text: 'Use cilantro for fresh flavor',
      reasoning: 'Bright herbal note',
      constraint_safe: true,
    },
    {
      dietaryRules: [dislike('cilantro')],
      availableEquipment: ['knife'],
    },
  );
  assertEquals(result.valid, false);
  assertEquals(result.issues.some((i) => i.kind === 'dislike_hard'), true);
});

Deno.test('validateSubstitution: equipment implication flagged when needle literal appears', () => {
  // EQUIPMENT_IMPLICATION keeps needles conservative — literal "blender"
  // triggers, not the verb "blend". Matches validateDish behavior so
  // the two code paths stay in sync.
  const result = validateSubstitution(
    {
      substitution_text: 'Use the blender on high speed',
      reasoning: 'Emulsifies the sauce',
      constraint_safe: true,
    },
    {
      dietaryRules: [],
      availableEquipment: ['stovetop', 'knife'],  // no blender
    },
  );
  assertEquals(result.valid, false);
  assertEquals(
    result.issues.some((i) => i.kind === 'unavailable_equipment_implied'),
    true,
  );
});

Deno.test('validateSubstitution: avoidEquipment union with unavailable', () => {
  // Blender IS in availableEquipment, but user's problem was "my
  // blender broke" — so caller passes blender in avoidEquipment. The
  // validator should still flag.
  const result = validateSubstitution(
    {
      substitution_text: 'Use the blender on high',
      reasoning: 'Emulsifies quickly',
      constraint_safe: true,
    },
    {
      dietaryRules: [],
      availableEquipment: ['blender', 'stovetop'],
      avoidEquipment: ['blender'],
    },
  );
  assertEquals(result.valid, false);
});

Deno.test('validateSubstitution: summarizeViolations emits PII-free kind labels', () => {
  const result = validateSubstitution(
    {
      substitution_text: 'Use peanut butter instead',
      reasoning: 'Nutty flavor',
      constraint_safe: true,
    },
    {
      dietaryRules: [allergy('peanut'), diet('gluten-free')],
      availableEquipment: ['stovetop'],
    },
  );
  const summary = summarizeViolations(result);
  assertEquals(summary.includes('allergens=peanut'), true);
  // No user text echoed back — only keyword labels.
  assertEquals(summary.includes('substitution_text'), false);
});

Deno.test('validateSubstitution: pescatarian diet blocks meat substitutions', () => {
  const result = validateSubstitution(
    {
      substitution_text: 'Use chicken breast instead',
      reasoning: 'Similar cooking time',
      constraint_safe: true,
    },
    {
      dietaryRules: [diet('pescatarian')],
      availableEquipment: ['skillet'],
    },
  );
  assertEquals(result.valid, false);
  assertEquals(result.issues.some((i) => i.kind === 'diet_violation'), true);
});

Deno.test('validateSubstitution: pescatarian diet allows fish substitutions', () => {
  const result = validateSubstitution(
    {
      substitution_text: 'Use cod fillet as a substitute',
      reasoning: 'Firm white fish with neutral flavor',
      constraint_safe: true,
    },
    {
      dietaryRules: [diet('pescatarian')],
      availableEquipment: ['skillet'],
    },
  );
  assertEquals(result.valid, true);
});

Deno.test('validateSubstitution: unknown diet value passes silently (no keywords)', () => {
  // A diet rule we don't have keywords for (e.g. "keto") shouldn't
  // falsely flag. The model prompt itself handles the semantic check;
  // the validator is a safety net, not the primary enforcement.
  const result = validateSubstitution(
    {
      substitution_text: 'Use coconut flour for baking',
      reasoning: 'Low-carb option',
      constraint_safe: true,
    },
    {
      dietaryRules: [diet('keto')],
      availableEquipment: ['oven'],
    },
  );
  assertEquals(result.valid, true);
});

// ---------------------------------------------------------------------------
// SCA-431 — pantry-grounded check
// ---------------------------------------------------------------------------
//
// The v1.1.0 substitution prompt forbids "from your pantry" /
// "in your pantry" / "you already have" unless the named ingredient
// actually appears in pantry_snapshot. This is the server-side belt
// for that copy rule — if the model ignores the prompt, the validator
// fires `ungrounded_pantry_claim` and the retry loop kicks in.
//
// Original SCA-424 production bug: model said "Use the baguette slices
// from your pantry" against a user whose pantry had zero baguettes
// (iOS was sending soft-deleted pantry rows). The iOS-side filter fix
// prevents the stale data; this hard-rule check is the independent
// server-side belt for the model-obedience failure mode.

Deno.test('validateSubstitution: SCA-431 — "from your pantry" with empty pantry fires ungrounded_pantry_claim', () => {
  const result = validateSubstitution(
    {
      substitution_text: 'Use the baguette slices from your pantry instead of flatbread.',
      reasoning: 'Toasted baguette provides a similar crunchy base for the pesto.',
      constraint_safe: true,
    },
    {
      dietaryRules: [],
      availableEquipment: ['skillet', 'oven'],
      pantrySnapshot: [], // user has nothing in their pantry
    },
  );
  assertEquals(result.valid, false);
  assertEquals(
    result.issues.some((i) => i.kind === 'ungrounded_pantry_claim'),
    true,
    'empty pantry + pantry claim should fire ungrounded_pantry_claim',
  );
});

Deno.test('validateSubstitution: SCA-431 — pantry claim grounded in snapshot passes', () => {
  const result = validateSubstitution(
    {
      substitution_text: 'Use the olive oil from your pantry instead of butter.',
      reasoning: 'Olive oil has similar fat content for sautéing.',
      constraint_safe: true,
    },
    {
      dietaryRules: [],
      availableEquipment: ['skillet'],
      pantrySnapshot: [{ display_name: 'olive oil' }, { display_name: 'kosher salt' }],
    },
  );
  assertEquals(
    result.valid,
    true,
    'pantry claim that names an actual pantry item must pass — that is the legitimate use case',
  );
});

Deno.test('validateSubstitution: SCA-431 — pantry claim naming non-pantry item fires ungrounded', () => {
  const result = validateSubstitution(
    {
      substitution_text: 'Use the baguette slices from your pantry instead of flatbread.',
      reasoning: 'Toasted baguette provides crunch.',
      constraint_safe: true,
    },
    {
      dietaryRules: [],
      availableEquipment: ['skillet'],
      // User has olive oil + salt, but model claimed baguettes.
      pantrySnapshot: [{ display_name: 'olive oil' }, { display_name: 'kosher salt' }],
    },
  );
  assertEquals(result.valid, false);
  assertEquals(
    result.issues.some((i) => i.kind === 'ungrounded_pantry_claim'),
    true,
    'pantry claim for an item that is NOT in pantry_snapshot must fire ungrounded_pantry_claim',
  );
});

Deno.test('validateSubstitution: SCA-431 — "in your pantry" + "you already have" also catch', () => {
  // Alternate phrasings the prompt forbids; all must fire on empty pantry.
  const phrasings = [
    'Use the saffron in your pantry to season the rice.',
    'You already have the right cheese — swap mozzarella for the parmesan.',
    'Use the leftover sourdough already in your pantry as a base.',
  ];
  for (const text of phrasings) {
    const result = validateSubstitution(
      {
        substitution_text: text,
        reasoning: 'Pantry-grounded suggestion.',
        constraint_safe: true,
      },
      {
        dietaryRules: [],
        availableEquipment: ['skillet'],
        pantrySnapshot: [], // ungrounded — no pantry to match
      },
    );
    assertEquals(
      result.valid,
      false,
      `phrasing "${text}" against empty pantry should fire ungrounded_pantry_claim`,
    );
  }
});

Deno.test('validateSubstitution: SCA-431 — pantry-grounded check is SKIPPED when pantrySnapshot is omitted', () => {
  // Back-compat: callers that don't thread pantrySnapshot through (any
  // legacy code path that calls validateSubstitution without it) keep
  // working — we don't suddenly retro-fail their output. The substitution
  // endpoint always provides the snapshot post-SCA-431.
  const result = validateSubstitution(
    {
      substitution_text: 'Use the baguette slices from your pantry instead of flatbread.',
      reasoning: 'Toasted baguette.',
      constraint_safe: true,
    },
    {
      dietaryRules: [],
      availableEquipment: ['skillet'],
      // pantrySnapshot intentionally OMITTED
    },
  );
  assertEquals(
    result.valid,
    true,
    'omitted pantrySnapshot must skip the check (legacy back-compat)',
  );
});

Deno.test('validateSubstitution: SCA-431 — summarizeViolations includes the offending phrasing', () => {
  const result = validateSubstitution(
    {
      substitution_text: 'Use the baguette slices from your pantry.',
      reasoning: 'x',
      constraint_safe: true,
    },
    {
      dietaryRules: [],
      availableEquipment: ['skillet'],
      pantrySnapshot: [],
    },
  );
  const summary = summarizeViolations(result);
  assertEquals(
    summary.includes('ungrounded_pantry_claim=from your pantry'),
    true,
    `summary should call out the forbidden phrasing for the retry prompt; got: ${summary}`,
  );
});

Deno.test('validateSubstitution: SCA-431 — model not making a pantry claim passes through', () => {
  // No "from your pantry" / "in your pantry" / "you already have" —
  // the check is gated on the phrasing being present, so absent
  // phrasing should never fire even with empty pantry.
  const result = validateSubstitution(
    {
      substitution_text: 'Use 2 Tbsp olive oil + 1 tsp lemon juice instead of 3 Tbsp butter.',
      reasoning: 'Matches the fat content and adds acidity.',
      constraint_safe: true,
    },
    {
      dietaryRules: [],
      availableEquipment: ['skillet'],
      pantrySnapshot: [],
    },
  );
  assertEquals(
    result.valid,
    true,
    'suggestion that does not claim "from your pantry" passes regardless of pantry contents',
  );
});
