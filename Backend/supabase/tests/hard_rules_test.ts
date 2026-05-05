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
  type SubstitutionCandidate,
  type SubstitutionContext,
  validateDish,
  validateSubstitution,
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

// -----------------------------------------------------------------------
// Allergen rawValue → keyword expansion (mockup 02 "nut-free" + tree_nut +
// shellfish coarse allergens). Plain-substring on bare rawValue alone
// misses real ingredient names; expansion covers species-level hits.
// -----------------------------------------------------------------------

Deno.test('hard-rules: nut allergy fires on almond (no "nut" substring)', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'almond flour', canonical_slug: 'almond-flour', amount_text: '1 cup', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('allergy', 'nut')] }));
  assertEquals(result.valid, false);
  assertEquals(result.issues[0]?.kind, 'allergen');
});

Deno.test('hard-rules: nut allergy fires on cashew (no "nut" substring)', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'cashew butter', canonical_slug: 'cashew-butter', amount_text: '2 tbsp', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('allergy', 'nut')] }));
  assertEquals(result.valid, false);
  assertEquals(result.issues[0]?.kind, 'allergen');
});

Deno.test('hard-rules: nut allergy still fires on walnut (substring "nut" hit)', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'walnuts', canonical_slug: null, amount_text: '1/4 cup', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('allergy', 'nut')] }));
  assertEquals(result.valid, false);
  assertEquals(result.issues[0]?.kind, 'allergen');
});

Deno.test('hard-rules: nut allergy fires on peanut (legume but mockup chip is coarse)', () => {
  // The mockup's "nut-free" chip makes no botanical distinction. A user
  // tapping it expects peanut protection too — even though peanuts are
  // a legume, not a tree nut.
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'peanut oil', canonical_slug: 'peanut-oil', amount_text: '2 tbsp', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('allergy', 'nut')] }));
  assertEquals(result.valid, false);
  assertEquals(result.issues[0]?.kind, 'allergen');
});

Deno.test('hard-rules: tree_nut allergy fires on almond / cashew / pistachio', () => {
  for (const ingredient of ['almonds', 'cashew cream', 'pistachio paste']) {
    const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
      ingredients: [{ display_name: ingredient, canonical_slug: null, amount_text: '1 cup', is_optional: false }],
    }});
    const result = validateDish(d, ctx({ dietaryRules: [rule('allergy', 'tree_nut')] }));
    assertEquals(result.valid, false, `tree_nut should fire on ${ingredient}`);
    assertEquals(result.issues[0]?.kind, 'allergen');
  }
});

Deno.test('hard-rules: tree_nut does NOT fire on peanut (legume, not tree nut)', () => {
  // tree_nut explicitly excludes peanut — user can pick both `peanut`
  // and `tree_nut` to cover everything; coarse `nut` covers both at once.
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'peanut butter', canonical_slug: 'peanut-butter', amount_text: '1/2 cup', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('allergy', 'tree_nut')] }));
  assertEquals(result.valid, true);
});

Deno.test('hard-rules: peanut allergy fires on groundnut (alt name)', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'groundnut oil', canonical_slug: null, amount_text: '2 tbsp', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('allergy', 'peanut')] }));
  assertEquals(result.valid, false);
  assertEquals(result.issues[0]?.kind, 'allergen');
});

Deno.test('hard-rules: shellfish allergy fires on shrimp / lobster / crab', () => {
  for (const ingredient of ['shrimp', 'lobster tail', 'crab meat']) {
    const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
      ingredients: [{ display_name: ingredient, canonical_slug: null, amount_text: '4 oz', is_optional: false }],
    }});
    const result = validateDish(d, ctx({ dietaryRules: [rule('allergy', 'shellfish')] }));
    assertEquals(result.valid, false, `shellfish should fire on ${ingredient}`);
    assertEquals(result.issues[0]?.kind, 'allergen');
  }
});

Deno.test('hard-rules: soy allergy fires on tofu / tempeh / miso (no "soy" substring)', () => {
  for (const ingredient of ['silken tofu', 'tempeh strips', 'white miso']) {
    const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
      ingredients: [{ display_name: ingredient, canonical_slug: null, amount_text: '4 oz', is_optional: false }],
    }});
    const result = validateDish(d, ctx({ dietaryRules: [rule('allergy', 'soy')] }));
    assertEquals(result.valid, false, `soy should fire on ${ingredient}`);
    assertEquals(result.issues[0]?.kind, 'allergen');
  }
});

Deno.test('hard-rules: peanut allergy unchanged on plain "peanut" (regression guard)', () => {
  // The expansion is additive; bare-rawValue substring must still hit.
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'peanuts', canonical_slug: null, amount_text: '1/4 cup', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('allergy', 'peanut')] }));
  assertEquals(result.valid, false);
  assertEquals(result.issues[0]?.kind, 'allergen');
});

// -----------------------------------------------------------------------
// Bare "nut" trigram word-boundary tightening (CA1-H4 / CA2-1 / DB1-2).
// The "nut" allergen rawValue's plain "nut" needle was matching benign
// foods (coconut, butternut squash, donut, nutmeg) and creating a slow
// retry / failed-rank cycle. WORD_BOUNDARY_KEYWORDS now contains 'nut',
// so containsAnyStrict applies word-boundary matching to that needle
// only. Species-level needles (almond, cashew, walnut, etc.) keep
// plain substring matching so the safety bar is unchanged.
// -----------------------------------------------------------------------

Deno.test('hard-rules: nut allergy does NOT fire on coconut (CA2-1)', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'coconut milk', canonical_slug: 'coconut-milk', amount_text: '1 can', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('allergy', 'nut')] }));
  assertEquals(result.valid, true, 'coconut should not trip nut allergy');
});

Deno.test('hard-rules: nut allergy does NOT fire on butternut squash (CA2-1)', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'butternut squash', canonical_slug: 'butternut-squash', amount_text: '1', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('allergy', 'nut')] }));
  assertEquals(result.valid, true, 'butternut should not trip nut allergy');
});

Deno.test('hard-rules: nut allergy does NOT fire on nutmeg (CA2-1)', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'nutmeg', canonical_slug: 'nutmeg', amount_text: '1 tsp', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('allergy', 'nut')] }));
  assertEquals(result.valid, true, 'nutmeg should not trip nut allergy');
});

Deno.test('hard-rules: nut allergy STILL fires on walnut after tightening', () => {
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'walnut halves', canonical_slug: null, amount_text: '1/2 cup', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('allergy', 'nut')] }));
  assertEquals(result.valid, false);
  assertEquals(result.issues[0]?.kind, 'allergen');
});

Deno.test('hard-rules: nut allergy STILL fires on bare "nut" word', () => {
  // Word-boundary still permits the plain "nut" word, just not as a
  // substring of compound words.
  const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
    ingredients: [{ display_name: 'mixed nuts', canonical_slug: null, amount_text: '1 cup', is_optional: false }],
  }});
  const result = validateDish(d, ctx({ dietaryRules: [rule('allergy', 'nut')] }));
  assertEquals(result.valid, false);
  assertEquals(result.issues[0]?.kind, 'allergen');
});

Deno.test('hard-rules: nut allergy fires on confection (marzipan/praline/nougat) (CA2-16)', () => {
  for (const ingredient of ['marzipan filling', 'praline topping', 'nougat layer', 'gianduja chocolate']) {
    const d = dish({ recipe_plan: { servings: 2, difficulty: 2, cuisine: null, steps: [],
      ingredients: [{ display_name: ingredient, canonical_slug: null, amount_text: '2 tbsp', is_optional: false }],
    }});
    const result = validateDish(d, ctx({ dietaryRules: [rule('allergy', 'nut')] }));
    assertEquals(result.valid, false, `nut should fire on ${ingredient}`);
    assertEquals(result.issues[0]?.kind, 'allergen');
  }
});

// -----------------------------------------------------------------------
// validateSubstitution-path coverage for allergen expansion (CR3-W9).
// Voice-mode substitutions reach the same validator via a different entry
// point. The two paths must have parity on what counts as an allergen.
// -----------------------------------------------------------------------

function sub(overrides: Partial<SubstitutionCandidate> = {}): SubstitutionCandidate {
  return {
    substitution_text: '',
    reasoning: '',
    amount_conversion: null,
    constraint_safe: true,
    ...overrides,
  };
}

function subCtx(overrides: Partial<SubstitutionContext> = {}): SubstitutionContext {
  return { dietaryRules: [], availableEquipment: [], ...overrides };
}

Deno.test('validateSubstitution: nut allergy fires on almond replacement', () => {
  const result = validateSubstitution(
    sub({ substitution_text: 'almond flour', reasoning: 'rich, gluten-free option' }),
    subCtx({ dietaryRules: [rule('allergy', 'nut')] }),
  );
  assertEquals(result.valid, false);
  assertEquals(result.issues[0]?.kind, 'allergen');
});

Deno.test('validateSubstitution: nut allergy does NOT fire on coconut replacement', () => {
  const result = validateSubstitution(
    sub({ substitution_text: 'coconut cream', reasoning: 'creamy dairy alternative' }),
    subCtx({ dietaryRules: [rule('allergy', 'nut')] }),
  );
  assertEquals(result.valid, true);
});

Deno.test('validateSubstitution: tree_nut allergy fires on cashew replacement', () => {
  const result = validateSubstitution(
    sub({ substitution_text: 'cashew butter', reasoning: 'similar texture to almond butter' }),
    subCtx({ dietaryRules: [rule('allergy', 'tree_nut')] }),
  );
  assertEquals(result.valid, false);
  assertEquals(result.issues[0]?.kind, 'allergen');
});

Deno.test('validateSubstitution: tree_nut does NOT fire on peanut replacement (legume)', () => {
  const result = validateSubstitution(
    sub({ substitution_text: 'peanut butter', reasoning: 'budget-friendly nutty alt' }),
    subCtx({ dietaryRules: [rule('allergy', 'tree_nut')] }),
  );
  assertEquals(result.valid, true);
});

Deno.test('validateSubstitution: peanut allergy fires on groundnut replacement', () => {
  const result = validateSubstitution(
    sub({ substitution_text: 'groundnut oil', reasoning: 'high smoke point' }),
    subCtx({ dietaryRules: [rule('allergy', 'peanut')] }),
  );
  assertEquals(result.valid, false);
  assertEquals(result.issues[0]?.kind, 'allergen');
});

Deno.test('validateSubstitution: shellfish allergy fires on shrimp replacement', () => {
  const result = validateSubstitution(
    sub({ substitution_text: 'shrimp paste', reasoning: 'umami bomb' }),
    subCtx({ dietaryRules: [rule('allergy', 'shellfish')] }),
  );
  assertEquals(result.valid, false);
  assertEquals(result.issues[0]?.kind, 'allergen');
});

Deno.test('validateSubstitution: soy allergy fires on tofu replacement', () => {
  const result = validateSubstitution(
    sub({ substitution_text: 'silken tofu', reasoning: 'plant-based protein source' }),
    subCtx({ dietaryRules: [rule('allergy', 'soy')] }),
  );
  assertEquals(result.valid, false);
  assertEquals(result.issues[0]?.kind, 'allergen');
});

Deno.test('validateSubstitution: nut allergy detects allergen in REASONING field', () => {
  // The validator joins substitution_text + reasoning + amount_conversion.
  // An allergen mentioned only in reasoning still flags.
  const result = validateSubstitution(
    sub({ substitution_text: 'sunflower seed butter', reasoning: 'tastes like almond' }),
    subCtx({ dietaryRules: [rule('allergy', 'nut')] }),
  );
  assertEquals(result.valid, false);
  assertEquals(result.issues[0]?.kind, 'allergen');
});
