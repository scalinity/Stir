// SCA-147 — Shared validation fixture factory.
//
// `RealtimeRecipeContext` (Backend/supabase/functions/_shared/validation.ts)
// is consumed by multiple handlers — `realtime-session` and `cook-turn`
// today; future voice-path additions inherit the same schema. Each
// handler's test file used to carry its own `validBody()` with a copy
// of the recipe_context + household_context shapes.
//
// On 2026-04-22 the shared schema tightened with a required `all_steps`
// field. Both test files drifted independently:
//   * realtime_session_test.ts fixed in 5348383
//   * cook_turn_test.ts fixed in e117af4
//
// SCA-147 collapses the two copies into one factory exported here. Any
// future `RealtimeRecipeContext` tighten requires updating exactly this
// file, not N test files.
//
// Scope: ONLY the shared sub-shapes (`recipe_context` and
// `household_context`). Each handler's full `validBody()` (with
// handler-specific fields like cook-turn's `transcript` or
// realtime-session's `is_refresh`) stays in the test file — those
// are not shared and don't have a drift problem.

/**
 * Realistic 5-step `recipe_context` matching the
 * `RealtimeRecipeContext` Zod schema. Multi-step rather than
 * one-element so tests inheriting the fixture exercise the
 * grounding path that was broken pre-2026-04-22 (production
 * hallucination on step 2 / asking about step 3).
 *
 * Pass `overrides` to swap individual fields. Keeps every test's
 * mutation surface explicit at its callsite.
 */
export function validRealtimeRecipeContext(
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    title: 'Tomato Cream Pasta',
    servings: 2,
    estimated_minutes: 20,
    total_steps: 5,
    current_step_text: 'Heat a large skillet over medium heat and add 2 Tbsp olive oil.',
    current_step_timer_seconds: 120,
    all_steps: [
      {
        step_number: 1,
        text: 'Heat a large skillet over medium heat and add 2 Tbsp olive oil.',
        timer_seconds: 120,
      },
      {
        step_number: 2,
        text: 'Add garlic and sauté until fragrant, about 1 minute.',
        timer_seconds: 60,
      },
      {
        step_number: 3,
        text: 'Add tomato paste and cook down until deepened in color.',
        timer_seconds: 180,
      },
      {
        step_number: 4,
        text: 'Stir in pasta and cream; toss to coat.',
        timer_seconds: 240,
      },
      {
        step_number: 5,
        text: 'Serve immediately with fresh basil.',
        timer_seconds: 0,
      },
    ],
    remaining_ingredients: [
      { display_name: 'pasta' },
      { display_name: 'garlic' },
    ],
    ...overrides,
  };
}

/**
 * Minimal `household_context` matching the shared schema. Two pantry
 * items + two pieces of equipment is enough to exercise the rendering
 * path without ballooning every test fixture.
 */
export function validHouseholdContext(
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    dietary_rules: [],
    available_equipment: ['stovetop', 'skillet'],
    pantry_snapshot: [
      { display_name: 'olive oil' },
      { display_name: 'tomato' },
    ],
    ...overrides,
  };
}
