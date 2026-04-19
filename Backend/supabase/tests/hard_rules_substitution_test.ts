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
