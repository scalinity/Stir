import { assertEquals } from '@std/assert';
import {
  finalizeSubstitution,
  SubstitutionOutput,
} from '../functions/_shared/substitution_output.ts';
import { validateStepRewrite } from '../functions/_shared/hard_rules.ts';
import {
  CookTurnRequest,
  RealtimeSessionRequest,
  RecipeStepRewriteRequest,
} from '../functions/_shared/validation.ts';
import {
  validHouseholdContext,
  validRealtimeRecipeContext,
} from './_helpers/fixtures/realtime_recipe_context.ts';

Deno.test('substitution: model refusals remain unsafe even when the keyword validator passes', () => {
  for (
    const reason of [
      'No safe alternative is available.',
      'The proposed method risks harmful food handling.',
    ]
  ) {
    const candidate = SubstitutionOutput.parse({
      substitution_text: 'Pause and choose another recipe.',
      constraint_safe: false,
      reasoning: reason,
      confidence: 'high',
    });
    const output = finalizeSubstitution(candidate, true);
    assertEquals(output.constraint_safe, false);
    assertEquals(output.amount_conversion, null);
    assertEquals(output.reasoning.includes(reason), false);
  }
});

Deno.test('substitution: server rejection cannot echo unsafe model prose in any visible field', () => {
  const candidate = SubstitutionOutput.parse({
    substitution_text: 'Use peanuts.',
    constraint_safe: true,
    reasoning: 'Use peanut oil.',
    constraint_violation_reason: 'Add peanuts.',
    confidence: 'high',
  });
  const output = finalizeSubstitution(candidate, false);
  assertEquals(output.constraint_safe, false);
  assertEquals(JSON.stringify(output).includes('peanut'), false);
});

Deno.test('rewrite: a safe swap does not permit newly generated allergens or the retained original', () => {
  const context = {
    dietaryRules: [{ kind: 'allergy', value: 'peanut', severity: 'hard' } as const],
    availableEquipment: ['stovetop'],
  };
  assertEquals(
    validateStepRewrite('Top with crushed peanuts.', 'peanuts', 'sunflower seeds', context).valid,
    false,
  );
  assertEquals(
    validateStepRewrite('Top with sunflower seeds.', 'peanuts', 'sunflower seeds', context).valid,
    true,
  );
  assertEquals(
    validateStepRewrite('Stir in the butter.', 'butter', 'olive oil', {
      dietaryRules: [],
      availableEquipment: [],
    }).valid,
    false,
  );
  assertEquals(
    validateStepRewrite('Stir in oat milk.', 'milk', 'oat milk', {
      dietaryRules: [],
      availableEquipment: [],
    }).valid,
    true,
  );
});

Deno.test('rewrite: household safety context is required, including an explicitly empty rules array', () => {
  const body = {
    sub_event_id: crypto.randomUUID(),
    step_instruction_text: 'Top with peanuts.',
    original_ingredient: 'peanuts',
    substitute_ingredient: 'sunflower seeds',
  };
  assertEquals(RecipeStepRewriteRequest.safeParse(body).success, false);
  assertEquals(
    RecipeStepRewriteRequest.safeParse({ ...body, dietary_rules: [], available_equipment: [] })
      .success,
    true,
  );
});

Deno.test('voice schemas accept the full imported recipe domain without truncation', () => {
  const recipe = validRealtimeRecipeContext({
    servings: 24,
    estimated_minutes: 1440,
    current_step_timer_seconds: 86400,
    all_steps: [{ step_number: 1, text: 'Simmer.', timer_seconds: 86400 }],
    remaining_ingredients: Array.from({ length: 100 }, () => ({ display_name: 'x'.repeat(256) })),
  });
  const body = {
    client_request_id: crypto.randomUUID(),
    cooking_session_id: crypto.randomUUID(),
    recipe_plan_id: crypto.randomUUID(),
    current_step_number: 1,
    recipe_context: recipe,
    household_context: validHouseholdContext(),
  };
  assertEquals(RealtimeSessionRequest.safeParse(body).success, true);
  assertEquals(CookTurnRequest.safeParse({ ...body, transcript: 'What next?' }).success, true);
  for (
    const [key, value] of [['servings', 25], ['estimated_minutes', 1441], [
      'current_step_timer_seconds',
      86401,
    ]]
  ) {
    assertEquals(
      RealtimeSessionRequest.safeParse({
        ...body,
        recipe_context: { ...recipe, [key as string]: value },
      }).success,
      false,
    );
  }
});
