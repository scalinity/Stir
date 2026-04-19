// hard_rules_test — unit tests for the hard-rule validator.
//
// Covers the false-positive regressions flagged by CA1/DB1 (eggplant,
// butternut, milk-thistle, chicken-of-the-woods, wheatgrass, buckwheat)
// plus the allergy-on-optional-ingredient safety rule (CR1-07) and
// exhaustive dietKeywordsFor() coverage (CR3-02).

import { assertEquals } from '@std/assert';
import {
  type CandidateDish,
  type DishContext,
  type DietaryRule,
  validateDish,
} from '../functions/_shared/hard_rules.ts';

function dish(overrides: Partial<CandidateDish> = {}): CandidateDish {
  return {
    rank: 1,
    title: 'Test',
    total_time_minutes: 20,
    why_it_fits: 'x',
    missing_ingredient_count: 0,
    fit_label_primary: 'best_fit',
    fit_label_secondary: null,
    hard_constraint_pass: true,
    recipe_plan: {
      servings: 2,
      difficulty: 2,
      cuisine: null,
      ingredients: [],
      steps: [],
    },
    reasoning_summary: 'x',
    ...overrides,
  } as CandidateDish;
}

function rule(kind: DietaryRule['kind'], value: string, severity: DietaryRule['severity'] = 'hard'): DietaryRule {
  return { kind, value, severity };
}

function ctx(overrides: Partial<DishContext> = {}): DishContext {
  return { dietaryRules: [], availableEquipment: [], ...overrides };
}

// -----------------------------------------------------------------------
// Word-boundary allergen matching (no more false positives)
// -----------------------------------------------------------------------

Deno.test('hard-rules: eggplant FIRES egg allergy (known safety-first FP)', () => {
  // Allergy rules deliberately use plain substring matching — preferring
  // a retry on a legitimate eggplant dish over a missed egg allergen.
  // The same conservatism applies to any "X-plant", "X-free", etc name
  // that contains the allergen as a substring. Documented, not fixed.
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'eggplant', canonical_slug: 'eggplant', amount_text: '1 large', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('allergy', 'egg')] }));
  assertEquals(result.valid, false);
  assertEquals(result.issues[0]?.kind, 'allergen');
});

Deno.test('hard-rules: eggplant passes egg-free DIET (word boundary)', () => {
  // Diet rules DO use word-boundary for short keywords. Eggplant in
  // a vegan-diet check must not trigger.
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'eggplant', canonical_slug: 'eggplant', amount_text: '1 large', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('diet', 'vegan')] }));
  assertEquals(result.valid, true);
});

Deno.test('hard-rules: butternut squash does NOT fire on dairy-free diet', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'butternut squash', canonical_slug: 'butternut-squash', amount_text: '1', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('diet', 'dairy-free')] }));
  assertEquals(result.valid, true);
});

Deno.test('hard-rules: chicken-of-the-woods mushroom passes vegetarian', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'chicken of the woods', canonical_slug: null, amount_text: '1 lb', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('diet', 'vegetarian')] }));
  assertEquals(result.valid, true);
});

Deno.test('hard-rules: buckwheat passes gluten-free', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'buckwheat flour', canonical_slug: 'buckwheat', amount_text: '2 cups', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('diet', 'gluten-free')] }));
  assertEquals(result.valid, true);
});

Deno.test('hard-rules: wheatgrass passes gluten-free', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'wheatgrass juice', canonical_slug: 'wheatgrass', amount_text: '1 shot', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('diet', 'gluten-free')] }));
  assertEquals(result.valid, true);
});

Deno.test('hard-rules: milk thistle passes dairy-free', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'milk thistle', canonical_slug: null, amount_text: '1 tsp', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('diet', 'dairy-free')] }));
  assertEquals(result.valid, true);
});

// -----------------------------------------------------------------------
// Must-still-fire cases (no false negatives)
// -----------------------------------------------------------------------

Deno.test('hard-rules: scrambled eggs still fires egg allergy', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'scrambled eggs', canonical_slug: null, amount_text: '3', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('allergy', 'egg')] }));
  assertEquals(result.valid, false);
});

Deno.test('hard-rules: chicken breast still fires vegetarian', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'chicken breast', canonical_slug: 'chicken', amount_text: '1 lb', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('diet', 'vegetarian')] }));
  assertEquals(result.valid, false);
});

Deno.test('hard-rules: butter still fires on vegan diet', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'butter', canonical_slug: null, amount_text: '2 tbsp', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('diet', 'vegan')] }));
  assertEquals(result.valid, false);
});

Deno.test('hard-rules: salmon fires vegetarian (long keyword unchanged)', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'salmon fillet', canonical_slug: null, amount_text: '1', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('diet', 'vegetarian')] }));
  assertEquals(result.valid, false);
});

// -----------------------------------------------------------------------
// is_optional gating (CR1-07: allergens run; dislike + diet skip)
// -----------------------------------------------------------------------

Deno.test('hard-rules: allergy fires even on is_optional ingredient (safety)', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'peanuts', canonical_slug: null, amount_text: '1/4 cup', is_optional: true }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('allergy', 'peanut')] }));
  assertEquals(result.valid, false);
});

Deno.test('hard-rules: dislike skips is_optional ingredient', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'cilantro', canonical_slug: null, amount_text: '1 tbsp', is_optional: true }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('dislike', 'cilantro')] }));
  assertEquals(result.valid, true);
});

Deno.test('hard-rules: diet skips is_optional ingredient', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'beef', canonical_slug: null, amount_text: '1 oz', is_optional: true }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('diet', 'vegetarian')] }));
  assertEquals(result.valid, true);
});

// -----------------------------------------------------------------------
// Diet keyword coverage (CR3-02)
// -----------------------------------------------------------------------

Deno.test('hard-rules: pescatarian blocks beef but allows salmon', () => {
  const beef = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'beef chuck', canonical_slug: null, amount_text: '1 lb', is_optional: false }],
  }});
  const salmon = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'salmon', canonical_slug: null, amount_text: '1', is_optional: false }],
  }});
  const c = ctx({ dietaryRules: [rule('diet', 'pescatarian')] });
  assertEquals(validateDish(beef, c).valid, false);
  assertEquals(validateDish(salmon, c).valid, true);
});

Deno.test('hard-rules: unknown diet passes silently (dietKeywordsFor → null)', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'beef', canonical_slug: null, amount_text: '1 lb', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('diet', 'halal')] }));
  assertEquals(result.valid, true); // 'halal' has no automated keyword list
});

// -----------------------------------------------------------------------
// Time + equipment checks
// -----------------------------------------------------------------------

Deno.test('hard-rules: time_over_budget fires when maxTimeMinutes < total', () => {
  const d = dish({ total_time_minutes: 60 });
  const result = validateDish(d, ctx({ maxTimeMinutes: 30 }));
  assertEquals(result.valid, false);
  assertEquals(result.issues.some((i) => i.kind === 'time_over_budget'), true);
});

Deno.test('hard-rules: time_over_budget not triggered when maxTimeMinutes undefined', () => {
  const d = dish({ total_time_minutes: 9999 });
  const result = validateDish(d, ctx());
  assertEquals(result.valid, true);
});

Deno.test('hard-rules: avoidEquipment contributes to unavailable set', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null,
    ingredients: [],
    steps: [{ step_number: 1, instruction_text: 'Set air fryer to 400F for 20 min.', timer_seconds: null }],
  }});
  const result = validateDish(d, {
    dietaryRules: [],
    availableEquipment: ['air_fryer'],
    avoidEquipment: ['air_fryer'],
  });
  assertEquals(result.valid, false);
});

// -----------------------------------------------------------------------
// claims_pass_falsely
// -----------------------------------------------------------------------

Deno.test('hard-rules: claims_pass_falsely added alongside the real issue', () => {
  const d = dish({
    hard_constraint_pass: true,
    recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
      ingredients: [{ display_name: 'chicken', canonical_slug: null, amount_text: '1 lb', is_optional: false }],
    },
  });
  const result = validateDish(d, ctx({ dietaryRules: [rule('diet', 'vegetarian')] }));
  assertEquals(result.valid, false);
  const kinds = result.issues.map((i) => i.kind);
  assertEquals(kinds.includes('claims_pass_falsely'), true);
  assertEquals(kinds.includes('diet_violation'), true);
});
