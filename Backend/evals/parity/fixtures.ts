// Parity-check fixtures: realistic request bodies for the text endpoints.
//
// Every body is built by a function so each run gets fresh idempotency ids
// (cached responses are never replayed). Shapes are derived from the Zod
// schemas in `_shared/validation.ts`; `validateFixtures()` parses every body
// against its schema and `run.ts` calls it before sending anything.
//
// One-off check (no network, no credits):
//   deno run --config Backend/supabase/functions/deno.json --allow-env --allow-read \
//     Backend/evals/parity/fixtures.ts [--images-dir <dir>]

import type { z } from 'zod';
import {
  CookTurnRequest,
  DinnerSolveRequest,
  GroceryGenerateRequest,
  PantryParseRequest,
  RecipeImportRequest,
  RecipeStepRewriteRequest,
  SubstitutionRequest,
} from '../../supabase/functions/_shared/validation.ts';

export type FeatureKey =
  | 'dinner_solve'
  | 'substitution'
  | 'recipe_step_rewrite'
  | 'cook_turn'
  | 'recipe_import'
  | 'grocery_generate'
  | 'pantry_parse';

export interface FeatureSpec {
  key: FeatureKey;
  /** Edge function directory name (`/functions/v1/<endpoint>`). */
  endpoint: string;
  /** Body field the endpoint writes to `ai_request_log.request_id`. */
  idField: string;
}

export const FEATURES: readonly FeatureSpec[] = [
  { key: 'dinner_solve', endpoint: 'dinner-solve', idField: 'solve_request_id' },
  { key: 'substitution', endpoint: 'substitution', idField: 'sub_event_id' },
  { key: 'recipe_step_rewrite', endpoint: 'recipe-step-rewrite', idField: 'sub_event_id' },
  { key: 'cook_turn', endpoint: 'cook-turn', idField: 'client_request_id' },
  { key: 'recipe_import', endpoint: 'recipe-import', idField: 'import_id' },
  { key: 'grocery_generate', endpoint: 'grocery-generate', idField: 'source_id' },
  { key: 'pantry_parse', endpoint: 'pantry-parse', idField: 'client_request_id' },
];

export interface Fixture {
  feature: FeatureKey;
  name: string;
  /** What the fixture exercises, shown next to the outputs in the report. */
  note: string;
  /** Builds a fresh body (new ids) on every call. */
  build: () => Record<string, unknown>;
}

const REQUEST_SCHEMAS: Record<FeatureKey, z.ZodTypeAny> = {
  dinner_solve: DinnerSolveRequest,
  substitution: SubstitutionRequest,
  recipe_step_rewrite: RecipeStepRewriteRequest,
  cook_turn: CookTurnRequest,
  recipe_import: RecipeImportRequest,
  grocery_generate: GroceryGenerateRequest,
  pantry_parse: PantryParseRequest,
};

// ---------------------------------------------------------------------------
// Shared builders
// ---------------------------------------------------------------------------

interface Rule {
  kind: 'allergy' | 'diet' | 'dislike' | 'goal';
  value: string;
  severity: 'hard' | 'soft';
}

const allergy = (value: string): Rule => ({ kind: 'allergy', value, severity: 'hard' });
const diet = (value: string): Rule => ({ kind: 'diet', value, severity: 'hard' });
const dislike = (value: string, severity: 'hard' | 'soft' = 'soft'): Rule => ({
  kind: 'dislike',
  value,
  severity,
});
const goal = (value: string): Rule => ({ kind: 'goal', value, severity: 'soft' });

const names = (list: readonly string[]) => list.map((display_name) => ({ display_name }));

// dinner-solve canaries a newer prompt for a share of requests, chosen by a
// hash of solve_request_id (`hashUuidToBucket100` in dinner-solve/index.ts).
// Random ids would put the same fixture on different prompt versions in the
// two runs and confound the comparison, so ids are drawn until the bucket is
// 99 — the default prompt for any rollout below 100%. This copy must track
// the handler's hash.
function bucket100(uuid: string): number {
  const hex = uuid.replace(/-/g, '');
  let x = 0;
  for (let i = 0; i < hex.length; i += 2) {
    const byte = parseInt(hex.slice(i, i + 2), 16);
    if (!Number.isNaN(byte)) x = ((x * 31) + byte) >>> 0;
  }
  return x % 100;
}

export function pinnedSolveRequestId(): string {
  for (;;) {
    const id = crypto.randomUUID();
    if (bucket100(id) === 99) return id;
  }
}

// ---------------------------------------------------------------------------
// dinner_solve
// ---------------------------------------------------------------------------

function dinnerBody(o: {
  ingredients: Array<Record<string, unknown>>;
  servings: number;
  rules?: Rule[];
  equipment: string[];
  constraints?: Record<string, unknown>;
  hint?: 'leftovers';
  leftovers?: Array<Record<string, unknown>>;
  feedback?: Record<string, unknown>;
}): Record<string, unknown> {
  return {
    solve_request_id: pinnedSolveRequestId(),
    ingredients: o.ingredients,
    ...(o.hint ? { context_hint: o.hint, leftovers_items: o.leftovers } : {}),
    ...(o.constraints ? { constraints: o.constraints } : {}),
    household_context: {
      servings: o.servings,
      dietary_rules: o.rules ?? [],
      available_equipment: o.equipment,
    },
    ...(o.feedback ? { feedback_summary: o.feedback } : {}),
  };
}

const DINNER_FIXTURES: Fixture[] = [
  {
    feature: 'dinner_solve',
    name: 'weeknight_basic',
    note: 'Baseline: no dietary rules, ordinary protein + veg + starch.',
    build: () =>
      dinnerBody({
        ingredients: [
          { display_name: 'chicken thighs', amount_text: '1.5 lb' },
          { display_name: 'jasmine rice', amount_text: '2 cups' },
          { display_name: 'broccoli', amount_text: '1 head' },
          { display_name: 'garlic', amount_text: '1 head' },
          { display_name: 'soy sauce' },
          { display_name: 'fresh ginger' },
        ],
        servings: 2,
        equipment: ['stovetop', 'skillet', 'oven', 'sheet_pan'],
      }),
  },
  {
    feature: 'dinner_solve',
    name: 'peanut_allergy_noodles',
    note: 'Hard peanut allergy with peanut butter sitting in the ingredient list (trap).',
    build: () =>
      dinnerBody({
        ingredients: names([
          'rice noodles',
          'firm tofu',
          'bok choy',
          'scallions',
          'sesame oil',
          'peanut butter',
          'limes',
          'sriracha',
          'carrots',
        ]),
        servings: 3,
        rules: [allergy('peanut')],
        equipment: ['stovetop', 'nonstick_pan'],
        constraints: { max_time_minutes: 30 },
      }),
  },
  {
    feature: 'dinner_solve',
    name: 'vegan_curry_dairy_traps',
    note: 'Hard vegan; butter and yogurt are in the ingredient list (traps). Goal: high protein.',
    build: () =>
      dinnerBody({
        ingredients: [
          { display_name: 'canned chickpeas', amount_text: '2 cans' },
          { display_name: 'spinach', amount_text: '1 bag' },
          { display_name: 'coconut milk', amount_text: '1 can' },
          { display_name: 'basmati rice' },
          { display_name: 'yellow onion' },
          { display_name: 'red curry paste' },
          { display_name: 'canned diced tomatoes' },
          { display_name: 'butter' },
          { display_name: 'plain yogurt' },
        ],
        servings: 4,
        rules: [diet('vegan')],
        equipment: ['stovetop', 'rice_cooker', 'dutch_oven'],
        constraints: { goal: 'high protein' },
      }),
  },
  {
    feature: 'dinner_solve',
    name: 'vegetarian_20_minutes',
    note: 'Hard vegetarian with chorizo present (trap), 20 minute cap, microwave + skillet only.',
    build: () =>
      dinnerBody({
        ingredients: [
          { display_name: 'eggs', amount_text: '6' },
          { display_name: 'flour tortillas' },
          { display_name: 'black beans', amount_text: '1 can' },
          { display_name: 'cheddar' },
          { display_name: 'avocado' },
          { display_name: 'salsa' },
          { display_name: 'chorizo' },
        ],
        servings: 2,
        rules: [diet('vegetarian')],
        equipment: ['microwave', 'stovetop', 'skillet'],
        constraints: { max_time_minutes: 20, goal: 'high protein' },
      }),
  },
  {
    feature: 'dinner_solve',
    name: 'shellfish_and_tree_nut_allergy',
    note: 'Two hard allergies; shrimp, almonds and pesto (pine nuts) are in the list (traps).',
    build: () =>
      dinnerBody({
        ingredients: [
          { display_name: 'salmon fillets', amount_text: '2' },
          { display_name: 'quinoa' },
          { display_name: 'asparagus', amount_text: '1 bunch' },
          { display_name: 'lemon' },
          { display_name: 'basil pesto' },
          { display_name: 'shrimp', amount_text: '1/2 lb' },
          { display_name: 'sliced almonds' },
        ],
        servings: 2,
        rules: [allergy('shellfish'), allergy('tree_nut')],
        equipment: ['oven', 'sheet_pan', 'stovetop'],
      }),
  },
  {
    feature: 'dinner_solve',
    name: 'gluten_free_dairy_free',
    note: 'Two hard diets; soy sauce (wheat), parmesan are in the list (traps).',
    build: () =>
      dinnerBody({
        ingredients: [
          { display_name: 'ground turkey', amount_text: '1 lb' },
          { display_name: 'rice noodles' },
          { display_name: 'zucchini', amount_text: '2' },
          { display_name: 'tamari' },
          { display_name: 'soy sauce' },
          { display_name: 'egg' },
          { display_name: 'fresh ginger' },
          { display_name: 'parmesan' },
          { display_name: 'sesame seeds' },
        ],
        servings: 4,
        rules: [diet('gluten_free'), diet('dairy_free')],
        equipment: ['stovetop', 'skillet'],
        constraints: { max_time_minutes: 35 },
      }),
  },
  {
    feature: 'dinner_solve',
    name: 'microwave_only_tiny_pantry',
    note: 'Equipment limit: microwave only, oven and stovetop avoided, 15 minute cap, 1 serving.',
    build: () =>
      dinnerBody({
        ingredients: [
          { display_name: 'eggs', amount_text: '4' },
          { display_name: 'sliced bread' },
          { display_name: 'cheddar' },
          { display_name: 'canned tuna', amount_text: '2 cans' },
          { display_name: 'mayonnaise' },
          { display_name: 'frozen peas' },
          { display_name: 'instant rice' },
        ],
        servings: 1,
        equipment: ['microwave'],
        constraints: { max_time_minutes: 15, avoid_equipment: ['oven', 'stovetop'] },
      }),
  },
  {
    feature: 'dinner_solve',
    name: 'use_first_italian',
    note: 'use_first + cuisine leaning + soft dislike (mushrooms) that is present in the list.',
    build: () =>
      dinnerBody({
        ingredients: [
          { display_name: 'baby spinach', amount_text: '5 oz, wilting' },
          { display_name: 'heavy cream', amount_text: '1 cup, expires tomorrow' },
          { display_name: 'penne' },
          { display_name: 'cremini mushrooms' },
          { display_name: 'parmesan' },
          { display_name: 'garlic' },
          { display_name: 'lemon' },
        ],
        servings: 2,
        rules: [dislike('mushrooms')],
        equipment: ['stovetop'],
        constraints: { use_first: ['baby spinach', 'heavy cream'], cuisine_leaning: 'Italian' },
      }),
  },
  {
    feature: 'dinner_solve',
    name: 'leftovers_mode',
    note: 'context_hint=leftovers (Premium+) with three leftover items to reuse.',
    build: () =>
      dinnerBody({
        ingredients: [
          { display_name: 'roast chicken', amount_text: 'about half a bird' },
          { display_name: 'cooked rice', amount_text: '2 cups' },
          { display_name: 'steamed broccoli', canonical_slug: 'broccoli' },
          { display_name: 'eggs' },
          { display_name: 'scallions' },
          { display_name: 'soy sauce' },
          { display_name: 'flour tortillas' },
        ],
        servings: 2,
        equipment: ['stovetop', 'skillet', 'microwave'],
        hint: 'leftovers',
        leftovers: [
          { display_name: 'roast chicken', approximate_amount_text: 'about half a bird' },
          { display_name: 'cooked rice', approximate_amount_text: '2 cups' },
          { display_name: 'steamed broccoli', canonical_slug: 'broccoli' },
        ],
      }),
  },
  {
    feature: 'dinner_solve',
    name: 'family_of_five_with_feedback',
    note:
      'Hard cilantro dislike (cilantro + olives present), 5 servings, preference-memory digest.',
    build: () =>
      dinnerBody({
        ingredients: [
          { display_name: 'pork shoulder', amount_text: '3 lb' },
          { display_name: 'ground beef', amount_text: '1 lb' },
          { display_name: 'pasta' },
          { display_name: 'canned crushed tomatoes' },
          { display_name: 'yellow onion' },
          { display_name: 'bell peppers', amount_text: '3' },
          { display_name: 'shredded cheddar' },
          { display_name: 'corn tortillas' },
          { display_name: 'cilantro' },
          { display_name: 'black olives' },
        ],
        servings: 5,
        rules: [dislike('cilantro', 'hard'), dislike('olives'), goal('kid friendly')],
        equipment: ['slow_cooker', 'instant_pot', 'stovetop', 'oven'],
        feedback: {
          recent_meal_count: 3,
          window_days: 30,
          recent_meals: [
            {
              title: 'Sheet Pan Nachos',
              rating: 5,
              workload: 'easy',
              taste: 'loved',
              spice_level: 'mild',
              would_repeat: true,
              cooked_days_ago: 4,
            },
            {
              title: 'Lentil Soup',
              rating: 2,
              workload: 'medium',
              taste: 'bad',
              spice_level: 'mild',
              would_repeat: false,
              cooked_days_ago: 9,
            },
            {
              title: 'Baked Ziti',
              rating: 4,
              workload: 'easy',
              taste: 'good',
              spice_level: 'mild',
              would_repeat: true,
              cooked_days_ago: 15,
            },
          ],
          aggregates: {
            average_rating: 3.7,
            dominant_taste: 'good',
            dominant_spice_level: 'mild',
            dominant_workload: 'easy',
            high_rated_rate: 0.67,
            would_repeat_rate: 0.67,
          },
          disliked_meals: ['Lentil Soup'],
          highlight_notes: [{
            title: 'Sheet Pan Nachos',
            rating: 5,
            note: 'kids asked for seconds',
          }],
        },
      }),
  },
];

// ---------------------------------------------------------------------------
// substitution
// ---------------------------------------------------------------------------

function subBody(o: {
  missing: Record<string, unknown>;
  problem: string;
  rules?: Rule[];
  equipment: string[];
  pantry: string[];
  title: string;
  step: number;
  remaining: string[];
  steps: string[];
  withStepList?: boolean;
}): Record<string, unknown> {
  return {
    sub_event_id: crypto.randomUUID(),
    cooking_session_id: crypto.randomUUID(),
    recipe_plan_id: crypto.randomUUID(),
    missing_ingredient: o.missing,
    user_problem: o.problem,
    household_context: {
      dietary_rules: o.rules ?? [],
      available_equipment: o.equipment,
      pantry_snapshot: names(o.pantry),
    },
    recipe_context: {
      title: o.title,
      current_step_number: o.step,
      total_steps: o.steps.length,
      remaining_ingredients: names(o.remaining),
      ...(o.withStepList
        ? {
          recipe_steps: o.steps.map((instruction, i) => ({
            step_number: i + 1,
            instruction,
            timer_seconds: null,
          })),
        }
        : {}),
    },
  };
}

const SUBSTITUTION_FIXTURES: Fixture[] = [
  {
    feature: 'substitution',
    name: 'cream_to_milk_and_butter',
    note: 'Baseline: no rules, a workable pantry-grounded swap exists (milk + butter).',
    build: () =>
      subBody({
        missing: { display_name: 'heavy cream', amount_text: '1 cup' },
        problem: 'I am out of heavy cream',
        equipment: ['stovetop', 'skillet'],
        pantry: ['whole milk', 'butter', 'flour'],
        title: 'Tomato Cream Pasta',
        step: 4,
        remaining: ['pasta', 'parmesan'],
        steps: [
          'Boil the pasta in salted water.',
          'Saute garlic in olive oil.',
          'Add crushed tomatoes and simmer 10 minutes.',
          'Stir in the heavy cream and simmer 3 minutes.',
          'Toss with pasta and parmesan.',
        ],
      }),
  },
  {
    feature: 'substitution',
    name: 'peanut_allergy_sesame_oil',
    note: 'Hard peanut allergy; peanut oil is in the pantry (trap).',
    build: () =>
      subBody({
        missing: { display_name: 'toasted sesame oil', amount_text: '1 Tbsp' },
        problem: 'we do not have sesame oil',
        rules: [allergy('peanut')],
        equipment: ['stovetop', 'nonstick_pan'],
        pantry: ['peanut oil', 'olive oil', 'rice vinegar', 'soy sauce', 'sesame seeds'],
        title: 'Garlic Green Bean Stir-Fry',
        step: 3,
        remaining: ['green beans', 'garlic', 'soy sauce'],
        steps: [
          'Trim the green beans.',
          'Heat a wok over high heat.',
          'Add the toasted sesame oil, then the beans and garlic.',
          'Splash in soy sauce and toss 2 minutes.',
        ],
      }),
  },
  {
    feature: 'substitution',
    name: 'vegan_egg_in_pancakes',
    note: 'Hard vegan; honey, milk and eggs-adjacent items in pantry (traps).',
    build: () =>
      subBody({
        missing: { display_name: 'eggs', amount_text: '2' },
        problem: 'no eggs',
        rules: [diet('vegan')],
        equipment: ['stovetop', 'griddle'],
        pantry: [
          'bananas',
          'unsweetened applesauce',
          'ground flaxseed',
          'honey',
          'whole milk',
          'oat milk',
        ],
        title: 'Fluffy Pancakes',
        step: 2,
        remaining: ['flour', 'baking powder', 'oat milk', 'vanilla'],
        steps: [
          'Whisk the dry ingredients.',
          'Whisk the eggs with milk and vanilla, then fold into the dry mix.',
          'Cook on a hot griddle until bubbles form, then flip.',
        ],
      }),
  },
  {
    feature: 'substitution',
    name: 'blender_broke',
    note: 'Equipment problem: blender removed from available equipment, food processor remains.',
    build: () =>
      subBody({
        missing: { display_name: 'blender' },
        problem: 'my blender just died',
        equipment: ['stovetop', 'skillet', 'food_processor'],
        pantry: ['olive oil', 'vegetable broth'],
        title: 'Roasted Tomato Soup',
        step: 4,
        remaining: ['roasted tomatoes', 'garlic', 'vegetable broth'],
        steps: [
          'Roast the tomatoes and garlic at 425F for 30 minutes.',
          'Transfer to a pot with the vegetable broth.',
          'Simmer 10 minutes.',
          'Blend the soup in a blender until completely smooth.',
        ],
      }),
  },
  {
    feature: 'substitution',
    name: 'gluten_free_thickener_free_text',
    note: 'Free-text missing ingredient; hard gluten-free; wheat flour in the pantry (trap).',
    build: () =>
      subBody({
        missing: { display_name: 'something to thicken the sauce' },
        problem: 'the sauce is too thin and I have no cornstarch',
        rules: [diet('gluten_free')],
        equipment: ['stovetop', 'skillet'],
        pantry: ['wheat flour', 'potato starch', 'almond flour', 'butter'],
        title: 'Lemon Chicken Pan Sauce',
        step: 5,
        remaining: ['chicken broth', 'lemon juice'],
        steps: [
          'Season and sear the chicken.',
          'Remove chicken and deglaze with broth.',
          'Add lemon juice.',
          'Simmer 3 minutes.',
          'Thicken with cornstarch slurry and return chicken to the pan.',
        ],
      }),
  },
  {
    feature: 'substitution',
    name: 'vegetarian_broth_chicken_stock_trap',
    note: 'Hard vegetarian; chicken stock in the pantry (trap); miso and mushrooms are valid.',
    build: () =>
      subBody({
        missing: { display_name: 'vegetable broth', amount_text: '4 cups' },
        problem: 'no vegetable broth for the risotto',
        rules: [diet('vegetarian')],
        equipment: ['stovetop', 'dutch_oven'],
        pantry: ['chicken stock', 'white miso', 'dried mushrooms', 'soy sauce', 'white wine'],
        title: 'Mushroom Risotto',
        step: 3,
        remaining: ['arborio rice', 'parmesan', 'mushrooms'],
        steps: [
          'Saute onions and mushrooms.',
          'Toast the rice for 2 minutes.',
          'Add the vegetable broth a ladle at a time, stirring.',
          'Finish with parmesan.',
        ],
      }),
  },
  {
    feature: 'substitution',
    name: 'oven_broken_baked_ziti',
    note: 'Equipment problem: oven removed; recipe step needs baking, stovetop available.',
    build: () =>
      subBody({
        missing: { display_name: 'oven' },
        problem: 'my oven stopped working mid-recipe',
        equipment: ['stovetop', 'skillet', 'microwave'],
        pantry: ['olive oil', 'mozzarella', 'parmesan'],
        title: 'Baked Ziti',
        step: 4,
        remaining: ['cooked ziti', 'marinara', 'mozzarella', 'ricotta'],
        steps: [
          'Boil the ziti until just al dente.',
          'Mix with marinara and ricotta.',
          'Top with mozzarella.',
          'Bake at 375F for 25 minutes until bubbling.',
        ],
      }),
  },
  {
    feature: 'substitution',
    name: 'tree_nut_allergy_almond_flour',
    note: 'Hard tree-nut allergy; walnuts in the pantry (trap); seed butter is valid.',
    build: () =>
      subBody({
        missing: { display_name: 'almond flour', amount_text: '1 cup' },
        problem: 'out of almond flour',
        rules: [allergy('tree_nut')],
        equipment: ['oven', 'sheet_pan'],
        pantry: ['rolled oats', 'walnuts', 'sunflower seed butter', 'oat flour', 'coconut flour'],
        title: 'Chewy Cookies',
        step: 2,
        remaining: ['brown sugar', 'egg', 'baking soda'],
        steps: [
          'Cream the butter and sugar.',
          'Mix in the egg and almond flour.',
          'Scoop onto a sheet pan.',
          'Bake 12 minutes.',
        ],
      }),
  },
  {
    feature: 'substitution',
    name: 'recipe_already_makes_it',
    note: 'recipe_steps supplied: the recipe itself makes flatbread from flour (SCA-425).',
    build: () =>
      subBody({
        missing: { display_name: 'flatbread', amount_text: '4' },
        problem: 'I have no flatbread',
        equipment: ['stovetop', 'skillet'],
        pantry: ['all-purpose flour', 'plain yogurt', 'olive oil', 'salt'],
        title: 'Chicken Shawarma Wraps',
        step: 1,
        remaining: ['chicken thighs', 'cucumber', 'tomato', 'flatbread'],
        steps: [
          'Mix flour, yogurt, oil and salt into a dough and cook rounds in a dry skillet to make flatbread.',
          'Cook the spiced chicken thighs in a skillet until browned.',
          'Slice the chicken and pile into the flatbread with cucumber and tomato.',
        ],
        withStepList: true,
      }),
  },
  {
    feature: 'substitution',
    name: 'dairy_free_coconut_milk_curry',
    note: 'Hard dairy-free + soft cilantro dislike; whole milk in pantry (trap).',
    build: () =>
      subBody({
        missing: { display_name: 'coconut milk', amount_text: '1 can' },
        problem: 'forgot to buy coconut milk',
        rules: [diet('dairy_free'), dislike('cilantro')],
        equipment: ['stovetop', 'dutch_oven'],
        pantry: ['whole milk', 'oat milk', 'raw cashews', 'tomato paste', 'vegetable broth'],
        title: 'Weeknight Chickpea Curry',
        step: 3,
        remaining: ['chickpeas', 'curry powder', 'spinach'],
        steps: [
          'Saute onion and garlic with curry powder.',
          'Add chickpeas.',
          'Pour in the coconut milk and simmer 15 minutes.',
          'Stir in spinach.',
        ],
      }),
  },
];

// ---------------------------------------------------------------------------
// recipe_step_rewrite
// ---------------------------------------------------------------------------
// Each sub_event_id is independent of the substitution fixtures: the endpoint
// writes `ai_request_log.request_id = sub_event_id` (primary key), so reusing
// an id would make the second insert a silent no-op.

function rewriteBody(o: {
  step: string;
  original: string;
  substitute: string;
  conversion?: string;
  title?: string;
}): Record<string, unknown> {
  return {
    sub_event_id: crypto.randomUUID(),
    step_instruction_text: o.step,
    original_ingredient: o.original,
    substitute_ingredient: o.substitute,
    dietary_rules: [],
    available_equipment: ['stovetop', 'oven'],
    ...(o.conversion ? { amount_conversion: o.conversion } : {}),
    ...(o.title ? { recipe_title: o.title } : {}),
  };
}

const REWRITE_FIXTURES: Fixture[] = [
  {
    feature: 'recipe_step_rewrite',
    name: 'flour_to_tortilla_chips',
    note: 'Dough step where the substitute changes texture.',
    build: () =>
      rewriteBody({
        step:
          'Mix flour, a pinch of salt, 1 tablespoon of oil, and approximately 1/4 cup of water to form a soft dough.',
        original: 'all-purpose flour',
        substitute: '1 cup of finely crushed tortilla chips',
        title: 'Quick Flatbread',
      }),
  },
  {
    feature: 'recipe_step_rewrite',
    name: 'butter_to_olive_oil',
    note: 'Quantity-bearing conversion supplied.',
    build: () =>
      rewriteBody({
        step:
          'Melt 4 tablespoons of butter in a large skillet over medium heat. Add the diced onion and cook until soft, about 5 minutes.',
        original: 'butter',
        substitute: 'olive oil',
        conversion: '3 Tbsp olive oil',
        title: 'Skillet Onion Pasta',
      }),
  },
  {
    feature: 'recipe_step_rewrite',
    name: 'egg_to_flax_egg',
    note: 'Substitute needs its own prep instruction.',
    build: () =>
      rewriteBody({
        step:
          'Whisk the egg with the milk and vanilla until smooth, then fold into the dry ingredients just until combined.',
        original: 'egg',
        substitute: 'flax egg (1 Tbsp ground flaxseed + 3 Tbsp water)',
        conversion: '1 flax egg per egg',
        title: 'Blueberry Muffins',
      }),
  },
  {
    feature: 'recipe_step_rewrite',
    name: 'blender_to_food_processor',
    note: 'Equipment swap rather than an ingredient swap.',
    build: () =>
      rewriteBody({
        step:
          'Blend the roasted tomatoes, garlic, and broth in a blender until completely smooth, working in batches if needed.',
        original: 'blender',
        substitute: 'food processor',
        title: 'Roasted Tomato Soup',
      }),
  },
  {
    feature: 'recipe_step_rewrite',
    name: 'broth_repeated_reference',
    note: 'The original is referenced twice in one step; no title, no conversion.',
    build: () =>
      rewriteBody({
        step:
          'Add the rice and 3 cups of chicken broth. Bring the broth to a boil, then reduce heat, cover, and simmer 18 minutes until the broth is absorbed.',
        original: 'chicken broth',
        substitute: 'vegetable broth',
      }),
  },
  {
    feature: 'recipe_step_rewrite',
    name: 'cream_to_coconut_milk',
    note: 'Step carries a technique warning tied to the original (do not boil).',
    build: () =>
      rewriteBody({
        step:
          'Stir in 1 cup heavy cream and simmer gently 5 minutes; do not let the cream boil or it may separate.',
        original: 'heavy cream',
        substitute: 'full-fat coconut milk',
        conversion: '1 cup (240 ml) coconut milk',
        title: 'Creamy Tomato Soup',
      }),
  },
  {
    feature: 'recipe_step_rewrite',
    name: 'soy_sauce_to_coconut_aminos',
    note: 'Multi-sentence step with a marinating time that must be preserved.',
    build: () =>
      rewriteBody({
        step:
          'Whisk together the soy sauce, rice vinegar, and honey. Pour half over the salmon and marinate for 15 minutes.',
        original: 'soy sauce',
        substitute: 'coconut aminos',
        conversion: '1:1, add a pinch more salt',
        title: 'Glazed Salmon',
      }),
  },
  {
    feature: 'recipe_step_rewrite',
    name: 'step_without_literal_mention',
    note: 'The original name never appears in the step text (only "the pasta").',
    build: () =>
      rewriteBody({
        step:
          'Cook the pasta until al dente, then drain, reserving 1/2 cup of the starchy water for the sauce.',
        original: 'spaghetti',
        substitute: 'spiralized zucchini',
        conversion: '12 oz spiralized zucchini; saute 2 minutes instead of boiling',
        title: 'Garlic Spaghetti',
      }),
  },
  {
    feature: 'recipe_step_rewrite',
    name: 'sugar_to_maple_syrup',
    note: 'Liquid replacing a dry ingredient in a long step.',
    build: () =>
      rewriteBody({
        step:
          'Beat the butter and 3/4 cup sugar until pale and fluffy, about 3 minutes. Scrape down the bowl, then add the eggs one at a time, beating well after each.',
        original: 'sugar',
        substitute: 'maple syrup',
        conversion: '1/2 cup maple syrup; reduce milk by 2 Tbsp',
        title: 'Simple Vanilla Cake',
      }),
  },
  {
    feature: 'recipe_step_rewrite',
    name: 'fresh_basil_to_dried',
    note: 'Fresh herb used as a finishing garnish becomes a dried herb.',
    build: () =>
      rewriteBody({
        step: 'Tear the basil leaves and scatter them over the pizza just before serving.',
        original: 'fresh basil',
        substitute: 'dried basil',
        conversion: '1 tsp dried basil per 1 Tbsp fresh',
        title: 'Margherita Flatbread',
      }),
  },
];

// ---------------------------------------------------------------------------
// cook_turn
// ---------------------------------------------------------------------------

interface StepSpec {
  text: string;
  timer: number | null;
}

interface RecipeSpec {
  title: string;
  servings: number;
  minutes: number;
  steps: StepSpec[];
  remaining: string[];
}

const FAJITAS: RecipeSpec = {
  title: 'Sheet-Pan Chicken Fajitas',
  servings: 4,
  minutes: 40,
  remaining: ['chicken breast', 'bell peppers', 'yellow onion', 'tortillas', 'limes'],
  steps: [
    { text: 'Preheat the oven to 425F and line a sheet pan with parchment.', timer: null },
    {
      text:
        'Toss sliced chicken breast, bell peppers, and onion with oil, chili powder, cumin, and salt on the pan.',
      timer: null,
    },
    {
      text: 'Roast 18 to 22 minutes, stirring halfway, until the chicken reaches 165F.',
      timer: 1200,
    },
    { text: 'Warm the tortillas in a dry skillet for 30 seconds per side.', timer: 60 },
    { text: 'Serve with lime wedges, avocado, and sour cream.', timer: null },
  ],
};

const SHRIMP_PASTA: RecipeSpec = {
  title: 'Garlic Butter Shrimp Pasta',
  servings: 2,
  minutes: 25,
  remaining: ['linguine', 'shrimp', 'butter', 'garlic', 'lemon', 'parsley'],
  steps: [
    { text: 'Bring a large pot of salted water to a boil.', timer: null },
    {
      text:
        'Cook the linguine until al dente, about 9 minutes. Reserve 1 cup of pasta water, then drain.',
      timer: 540,
    },
    {
      text:
        'Melt butter in a skillet over medium heat, add 4 cloves minced garlic, and cook 30 seconds.',
      timer: 30,
    },
    { text: 'Add the shrimp and cook 2 minutes per side until pink.', timer: 240 },
    {
      text: 'Toss the pasta with the shrimp, lemon juice, parsley and a splash of pasta water.',
      timer: null,
    },
  ],
};

const LENTIL_SOUP: RecipeSpec = {
  title: 'Smoky Lentil Soup',
  servings: 4,
  minutes: 55,
  remaining: ['brown lentils', 'diced tomatoes', 'vegetable broth', 'spinach', 'lemon'],
  steps: [
    { text: 'Saute diced onion, carrot, and celery in olive oil for 8 minutes.', timer: 480 },
    { text: 'Stir in garlic, cumin, and smoked paprika; cook 1 minute.', timer: 60 },
    {
      text: 'Add the lentils, diced tomatoes, and 6 cups of vegetable broth. Bring to a boil.',
      timer: null,
    },
    { text: 'Simmer, partially covered, 30 minutes until the lentils are tender.', timer: 1800 },
    { text: 'Stir in the spinach and lemon juice.', timer: null },
  ],
};

const PANCAKES: RecipeSpec = {
  title: 'Buttermilk Pancakes',
  servings: 3,
  minutes: 25,
  remaining: ['flour', 'baking powder', 'milk', 'egg', 'butter'],
  steps: [
    {
      text: 'Whisk 1 1/2 cups flour, 1 Tbsp sugar, 2 tsp baking powder and 1/2 tsp salt.',
      timer: null,
    },
    {
      text:
        'In another bowl whisk 1 1/4 cups milk, 1 egg and 3 Tbsp melted butter; stir into the dry ingredients until just combined.',
      timer: null,
    },
    {
      text:
        'Heat a griddle over medium heat. Pour 1/4 cup batter per pancake, cook until bubbles form, then flip.',
      timer: 150,
    },
    { text: 'Serve warm with maple syrup.', timer: null },
  ],
};

const SESAME_NOODLES: RecipeSpec = {
  title: 'Cold Sesame Noodles',
  servings: 2,
  minutes: 20,
  remaining: ['noodles', 'soy sauce', 'rice vinegar', 'sesame oil', 'cucumber', 'scallions'],
  steps: [
    {
      text: 'Cook the noodles per package directions, drain, and rinse with cold water.',
      timer: null,
    },
    {
      text: 'Whisk soy sauce, rice vinegar, sesame oil and chili crisp for the dressing.',
      timer: null,
    },
    { text: 'Toss the noodles with the dressing, cucumber, and scallions.', timer: null },
    { text: 'Top with toasted sesame seeds.', timer: null },
  ],
};

function cookTurnBody(o: {
  recipe: RecipeSpec;
  step: number;
  transcript: string;
  rules?: Rule[];
  equipment?: string[];
  pantry?: string[];
}): Record<string, unknown> {
  const current = o.recipe.steps[o.step - 1];
  if (!current) throw new Error(`cook_turn fixture: step ${o.step} out of range`);
  return {
    client_request_id: crypto.randomUUID(),
    cooking_session_id: crypto.randomUUID(),
    recipe_plan_id: crypto.randomUUID(),
    current_step_number: o.step,
    transcript: o.transcript,
    recipe_context: {
      title: o.recipe.title,
      servings: o.recipe.servings,
      estimated_minutes: o.recipe.minutes,
      total_steps: o.recipe.steps.length,
      current_step_text: current.text,
      current_step_timer_seconds: current.timer,
      all_steps: o.recipe.steps.map((s, i) => ({
        step_number: i + 1,
        text: s.text,
        timer_seconds: s.timer,
      })),
      remaining_ingredients: names(o.recipe.remaining),
    },
    household_context: {
      dietary_rules: o.rules ?? [],
      available_equipment: o.equipment ?? ['stovetop', 'skillet', 'oven', 'sheet_pan'],
      pantry_snapshot: names(o.pantry ?? ['olive oil', 'salt', 'black pepper']),
    },
  };
}

const COOK_TURN_FIXTURES: Fixture[] = [
  {
    feature: 'cook_turn',
    name: 'fajitas_doneness',
    note: 'Factual question about the current step; expected action none.',
    build: () =>
      cookTurnBody({
        recipe: FAJITAS,
        step: 3,
        transcript: 'how do I know when the chicken is done',
      }),
  },
  {
    feature: 'cook_turn',
    name: 'fajitas_advance',
    note: 'User asks to move on; expected action advance_step.',
    build: () =>
      cookTurnBody({
        recipe: FAJITAS,
        step: 1,
        transcript: 'okay the oven is preheated, what is next',
      }),
  },
  {
    feature: 'cook_turn',
    name: 'fajitas_start_timer',
    note: 'Explicit timer request; expected action start_timer with seconds=1200.',
    build: () =>
      cookTurnBody({ recipe: FAJITAS, step: 3, transcript: 'start a timer for twenty minutes' }),
  },
  {
    feature: 'cook_turn',
    name: 'pasta_foaming_over',
    note: 'Urgent troubleshooting, short spoken answer wanted.',
    build: () =>
      cookTurnBody({
        recipe: SHRIMP_PASTA,
        step: 2,
        transcript: 'my pasta water is foaming over what do I do',
      }),
  },
  {
    feature: 'cook_turn',
    name: 'pasta_garlic_browning',
    note: 'Judgment question with step context (30 second garlic).',
    build: () =>
      cookTurnBody({
        recipe: SHRIMP_PASTA,
        step: 3,
        transcript: 'is it okay if the garlic turns a little brown',
      }),
  },
  {
    feature: 'cook_turn',
    name: 'pasta_recall_earlier_step',
    note: 'Grounding: asks about step 2 while on step 4 (answer must come from all_steps).',
    build: () =>
      cookTurnBody({
        recipe: SHRIMP_PASTA,
        step: 4,
        transcript: 'what did I do with the pasta water again',
      }),
  },
  {
    feature: 'cook_turn',
    name: 'vegan_asks_chicken_stock',
    note: 'Hard vegan; user proposes chicken stock (should decline / redirect).',
    build: () =>
      cookTurnBody({
        recipe: LENTIL_SOUP,
        step: 4,
        transcript: 'can I stir in some chicken stock to boost the flavor',
        rules: [diet('vegan')],
        equipment: ['stovetop', 'dutch_oven'],
        pantry: ['chicken stock', 'olive oil', 'nutritional yeast'],
      }),
  },
  {
    feature: 'cook_turn',
    name: 'vegan_asks_butter_finish',
    note: 'Hard vegan; user proposes butter to finish.',
    build: () =>
      cookTurnBody({
        recipe: LENTIL_SOUP,
        step: 5,
        transcript: 'can I add a spoon of butter at the end',
        rules: [diet('vegan')],
        equipment: ['stovetop', 'dutch_oven'],
        pantry: ['butter', 'olive oil', 'tahini'],
      }),
  },
  {
    feature: 'cook_turn',
    name: 'peanut_allergy_asks_peanuts',
    note: 'Hard peanut allergy; user proposes crushed peanuts as a topping.',
    build: () =>
      cookTurnBody({
        recipe: SESAME_NOODLES,
        step: 4,
        transcript: 'can I top it with some crushed peanuts',
        rules: [allergy('peanut')],
        equipment: ['stovetop'],
        pantry: ['peanuts', 'sesame seeds', 'chili crisp'],
      }),
  },
  {
    feature: 'cook_turn',
    name: 'off_topic_joke',
    note: 'Off-topic request mid-cook; checks the persona stays in scope and brief.',
    build: () =>
      cookTurnBody({
        recipe: PANCAKES,
        step: 3,
        transcript: 'tell me a joke while these cook',
        equipment: ['stovetop', 'griddle'],
      }),
  },
];

// ---------------------------------------------------------------------------
// recipe_import (pasted_text only; no URL fetching)
// ---------------------------------------------------------------------------
// Every text stays well under the handler's 8192-byte async threshold so the
// request is answered synchronously rather than queued.

const lines = (...l: string[]) => l.join('\n');

const IMPORT_TEXTS: Array<{ name: string; note: string; text: string }> = [
  {
    name: 'banana_bread_clean',
    note: 'Clean blog-style recipe with headed sections and numbered steps.',
    text: lines(
      'Classic Banana Bread',
      'Prep 10 min | Bake 55 min | Makes 1 loaf (10 slices)',
      '',
      'Ingredients',
      '3 very ripe bananas, mashed',
      '1/3 cup (75 g) melted butter',
      '3/4 cup (150 g) sugar',
      '1 egg, beaten',
      '1 tsp vanilla extract',
      '1 tsp baking soda',
      'Pinch of salt',
      '1 1/2 cups (190 g) all-purpose flour',
      '',
      'Instructions',
      '1. Preheat the oven to 350F (175C) and butter a 9x5 inch loaf pan.',
      '2. Mash the bananas in a large bowl, then stir in the melted butter.',
      '3. Mix in the sugar, egg and vanilla. Sprinkle the baking soda and salt over the top and stir in.',
      '4. Add the flour and mix until just combined.',
      '5. Pour into the pan and bake 50 to 55 minutes, until a toothpick comes out clean.',
      '6. Cool in the pan 10 minutes, then turn out onto a rack.',
    ),
  },
  {
    name: 'roast_potatoes_metric_uk',
    note: 'UK phrasing: grams, fan oven temperatures, "tablespoon" abbreviations.',
    text: lines(
      'Sunday Roast Potatoes',
      'Serves 4-6',
      '',
      '1.5kg maris piper potatoes, peeled and halved',
      '4 tbsp goose fat or sunflower oil',
      '1 tsp sea salt flakes',
      '4 garlic cloves, left in their skins',
      '2 sprigs rosemary',
      '',
      'Method',
      'Heat oven to 220C/200C fan/gas 7. Put the potatoes in a large pan of salted water, bring to the boil and simmer for 8 mins. Drain and leave to steam for 5 mins, then shake the pan roughly to fluff up the edges.',
      'Pour the fat into a roasting tin and heat in the oven for 10 mins until very hot. Tip in the potatoes, turn to coat, and roast for 30 mins.',
      'Turn the potatoes, add the garlic and rosemary and roast for a further 25-30 mins until deep golden and crisp.',
    ),
  },
  {
    name: 'grandmas_chili_narrative',
    note: 'Narrative paragraphs with quantities buried in the prose, no lists.',
    text: lines(
      "My grandmother's chili was never written down, so this is my best attempt. Start by browning two pounds of ground beef in a big heavy pot with one chopped onion until the pink is gone, then drain most of the fat.",
      'Stir in three cloves of garlic, three tablespoons of chili powder, a tablespoon of cumin and a teaspoon of oregano and let it toast for a minute. Add a 28-ounce can of crushed tomatoes, a can of tomato sauce, two cans of drained kidney beans and a cup of water.',
      'Let it simmer on low, lid cracked, for about an hour and a half, stirring now and then, until thick. Salt to taste at the end. She always served it over a pile of crushed saltines with cheddar on top.',
    ),
  },
  {
    name: 'meatloaf_index_card',
    note:
      'Index-card shorthand: abbreviations, missing verbs, oven time fused into the ingredient list.',
    text: lines(
      "MOM'S MEATLOAF",
      '2 lb grd beef',
      '1 c. bread crumbs',
      '1 egg',
      '1/2 c. milk',
      '1 sm onion chopped fine',
      '1 tsp salt, pepper',
      '1/2 c. ketchup (+ 1/4 c. for top)',
      '2 T brown sugar for top',
      'mix everything but top stuff w/ hands. shape in loaf pan. spread ketchup + sugar on top.',
      'Bake 350 1 hr 15. rest 10 min before slicing!!',
    ),
  },
  {
    name: 'feta_pasta_social_caption',
    note: 'Social-media caption: emojis, hashtags, ALL CAPS, informal steps.',
    text: lines(
      'THE VIRAL BAKED FETA PASTA YOU NEED TO TRY \u{1F924}\u{1F525}',
      'literally 5 ingredients and one pan!!',
      '',
      '\u{1F345} 2 pints cherry tomatoes',
      '\u{1F9C0} 8 oz block of feta',
      '\u{1FAD2} 1/3 cup olive oil',
      '\u{1F9C4} 4 cloves garlic',
      '\u{1F35D} 12 oz rigatoni or penne',
      '+ salt, pepper, red pepper flakes, basil',
      '',
      'Put tomatoes + garlic in a baking dish, drizzle w oil, season, nestle the feta in the middle. Bake at 400 for 35 min until jammy. Meanwhile boil pasta. Smash the feta + tomatoes together, toss w pasta and top w basil \u{1F60D}',
      '#fetapasta #easydinner #weeknightmeals #foodtok',
    ),
  },
  {
    name: 'thai_green_curry_grouped',
    note: 'Ingredient groups ("For the paste" / "For the curry") that map to the group field.',
    text: lines(
      'Thai Green Chicken Curry',
      'Serves 4. Total time 45 minutes.',
      '',
      'For the paste:',
      '4 green Thai chilies',
      '2 shallots, roughly chopped',
      '3 cloves garlic',
      '1 inch piece galangal or ginger',
      '1 stalk lemongrass, white part only',
      '1 tsp ground coriander',
      '1 tbsp fish sauce',
      '',
      'For the curry:',
      '1 tbsp coconut oil',
      '1 lb chicken thighs, sliced',
      '1 can (13.5 oz) coconut milk',
      '1 cup chicken stock',
      '1 cup Thai eggplant or zucchini, cubed',
      '1 tbsp palm sugar or brown sugar',
      'Handful of Thai basil',
      '',
      'Blitz the paste ingredients in a food processor until smooth. Heat the coconut oil in a wok and fry 3 tablespoons of paste for 2 minutes until fragrant. Add the chicken and cook 4 minutes. Pour in the coconut milk and stock, add the eggplant and sugar, and simmer 15 minutes. Finish with the basil and serve over rice.',
    ),
  },
  {
    name: 'tikka_masala_noisy_web_copy',
    note: 'Scraped page: navigation text, ad copy, ratings and comments around the recipe.',
    text: lines(
      'Home > Recipes > Dinner > Chicken Tikka Masala',
      'Jump to Recipe • Print Recipe • Pin • Share',
      'The BEST Chicken Tikka Masala (Ready in 40 Minutes!)',
      '★★★★★ 4.9 from 1,284 reviews',
      "If you've been searching for a restaurant-style tikka masala, look no further. Subscribe to our newsletter for 20% off your first order!",
      'INGREDIENTS',
      '1.5 lbs boneless chicken breast, cubed',
      '3/4 cup plain yogurt',
      '2 tbsp garam masala, divided',
      '1 tbsp ginger-garlic paste',
      '2 tbsp butter',
      '1 onion, diced',
      '1 can (15 oz) tomato sauce',
      '3/4 cup heavy cream',
      'Salt to taste',
      'DIRECTIONS',
      'Marinate the chicken in the yogurt, 1 tbsp garam masala and the ginger-garlic paste for at least 20 minutes.',
      'Melt the butter in a large skillet and brown the chicken in batches, about 5 minutes. Set aside.',
      'Saute the onion in the same pan 4 minutes, add the remaining garam masala, the tomato sauce and simmer 10 minutes.',
      'Stir in the cream and chicken and simmer another 8 minutes.',
      'Advertisement • Sponsored: Try HelloFresh today',
      'Comments (212)',
      'Sarah says: Made this last night, my family loved it! I added a pinch of sugar.',
      'Mike says: Too salty for me, cut the salt in half.',
    ),
  },
  {
    name: 'focaccia_unicode_fractions_long_waits',
    note: 'Unicode fractions and long passive waits (rise times) in the steps.',
    text: lines(
      'Overnight Focaccia',
      'Makes one 9x13 pan',
      '',
      '3½ cups (440 g) bread flour',
      '2¼ tsp instant yeast',
      '2 tsp fine salt',
      '1¾ cups lukewarm water',
      '¼ cup olive oil, plus more for the pan',
      'Flaky salt and rosemary for the top',
      '',
      '1. Stir flour, yeast, salt and water in a large bowl until no dry flour remains. Cover and let rest 12 to 18 hours at room temperature.',
      '2. Oil a 9x13 pan with ¼ cup olive oil. Scrape the dough into the pan, fold it over itself once, and let rise 1½ hours until puffy.',
      '3. Heat oven to 450F. Dimple the dough with oiled fingers, scatter with flaky salt and rosemary.',
      '4. Bake 22 to 25 minutes until deeply golden. Cool 10 minutes in the pan.',
    ),
  },
  {
    name: 'kimchi_fried_rice_inline_steps',
    note:
      'Steps run together in one paragraph with inline "1)" "2)" markers; no ingredient heading.',
    text: lines(
      'Kimchi Fried Rice (serves 2)',
      'You need: 2 cups day-old cooked rice, 1 cup chopped kimchi plus 2 tbsp of its juice, 4 oz sliced pork belly or bacon, 2 scallions sliced, 1 tbsp gochujang, 1 tsp sesame oil, 2 eggs, 1 tsp neutral oil.',
      '1) Cook the pork in a hot wok until crisp, about 4 minutes. 2) Add the kimchi and cook 3 minutes until it caramelizes at the edges. 3) Stir in the gochujang and kimchi juice, then the rice, breaking up clumps, and fry 4 minutes. 4) Push the rice aside, fry the eggs sunny side up in the neutral oil. 5) Finish rice with sesame oil and scallions and top each bowl with an egg.',
    ),
  },
  {
    name: 'pico_de_gallo_no_steps',
    note: 'Ingredients plus a one-line blurb only; expect low parse quality / edit hints.',
    text: lines(
      'Pico de gallo',
      'tomatoes (4 roma), 1/2 white onion, 1-2 jalapenos, big handful cilantro, 2 limes, salt',
      'chop everything small and mix. better after 30 mins.',
    ),
  },
];

const IMPORT_FIXTURES: Fixture[] = IMPORT_TEXTS.map((t) => ({
  feature: 'recipe_import' as const,
  name: t.name,
  note: t.note,
  build: () => ({
    import_id: crypto.randomUUID(),
    source_type: 'pasted_text',
    payload: { pasted_text: t.text },
  }),
}));

// ---------------------------------------------------------------------------
// grocery_generate
// ---------------------------------------------------------------------------

function groceryBody(o: {
  type: 'recipe' | 'session' | 'leftovers';
  needed: Array<Record<string, unknown>>;
  pantry: string[];
  title?: string;
}): Record<string, unknown> {
  return {
    source_id: crypto.randomUUID(),
    source_type: o.type,
    ingredients_needed: o.needed,
    pantry_snapshot: names(o.pantry),
    ...(o.title ? { recipe_title: o.title } : {}),
  };
}

const GROCERY_FIXTURES: Fixture[] = [
  {
    feature: 'grocery_generate',
    name: 'garlic_chicken_basic',
    note: 'Baseline: three items, two partially covered by the pantry.',
    build: () =>
      groceryBody({
        type: 'recipe',
        needed: [
          { display_name: 'chicken thighs', amount_text: '1.5 lbs' },
          { display_name: 'olive oil', amount_text: '2 tbsp' },
          { display_name: 'garlic', amount_text: '4 cloves' },
        ],
        pantry: ['olive oil', 'salt'],
        title: 'Garlic Roasted Chicken Thighs',
      }),
  },
  {
    feature: 'grocery_generate',
    name: 'alias_names_scallions_limes',
    note: 'Pantry uses different names for the same items (green onions, limes, coconut cream).',
    build: () =>
      groceryBody({
        type: 'recipe',
        needed: [
          { display_name: 'scallions', amount_text: '4' },
          { display_name: 'lime', amount_text: '2' },
          { display_name: 'coconut milk', amount_text: '1 can' },
          { display_name: 'fresh cilantro', amount_text: '1 bunch' },
          { display_name: 'jasmine rice', amount_text: '2 cups' },
        ],
        pantry: ['green onions', 'limes', 'coconut cream', 'basmati rice'],
        title: 'Coconut Lime Rice Bowls',
      }),
  },
  {
    feature: 'grocery_generate',
    name: 'pantry_covers_everything',
    note: 'Nothing should be missing; extra-virgin variant of the same oil counts.',
    build: () =>
      groceryBody({
        type: 'recipe',
        needed: [
          { display_name: 'spaghetti', amount_text: '1 lb' },
          { display_name: 'olive oil', amount_text: '1/4 cup' },
          { display_name: 'garlic', amount_text: '6 cloves' },
          { display_name: 'parmesan', amount_text: '1/2 cup' },
          { display_name: 'black pepper' },
        ],
        pantry: [
          'spaghetti',
          'extra virgin olive oil',
          'garlic',
          'parmigiano reggiano',
          'black pepper',
        ],
        title: 'Aglio e Olio',
      }),
  },
  {
    feature: 'grocery_generate',
    name: 'empty_pantry_lasagna',
    note: 'Empty pantry, twelve items across every category.',
    build: () =>
      groceryBody({
        type: 'recipe',
        needed: [
          { display_name: 'lasagna noodles', amount_text: '12' },
          { display_name: 'ground beef', amount_text: '1 lb' },
          { display_name: 'Italian sausage', amount_text: '1/2 lb' },
          { display_name: 'ricotta', amount_text: '15 oz' },
          { display_name: 'mozzarella', amount_text: '3 cups shredded' },
          { display_name: 'parmesan', amount_text: '1 cup' },
          { display_name: 'marinara sauce', amount_text: '24 oz' },
          { display_name: 'yellow onion', amount_text: '1' },
          { display_name: 'garlic', amount_text: '4 cloves' },
          { display_name: 'egg', amount_text: '1' },
          { display_name: 'fresh basil', amount_text: '1 handful' },
          { display_name: 'frozen spinach', amount_text: '10 oz' },
        ],
        pantry: [],
        title: 'Classic Meat Lasagna',
      }),
  },
  {
    feature: 'grocery_generate',
    name: 'staples_salt_flour_sugar',
    note: 'Staples with qualifiers (kosher salt, all-purpose flour) against plainer pantry names.',
    build: () =>
      groceryBody({
        type: 'recipe',
        needed: [
          { display_name: 'kosher salt', amount_text: '1 tsp' },
          { display_name: 'all-purpose flour', amount_text: '2 cups' },
          { display_name: 'granulated sugar', amount_text: '1/2 cup' },
          { display_name: 'unsalted butter', amount_text: '1 stick' },
          { display_name: 'baking powder', amount_text: '2 tsp' },
          { display_name: 'buttermilk', amount_text: '1 cup' },
          { display_name: 'water' },
        ],
        pantry: ['sea salt', 'flour', 'sugar', 'butter'],
        title: 'Buttermilk Biscuits',
      }),
  },
  {
    feature: 'grocery_generate',
    name: 'taco_night_large_list',
    note: 'Large list (24 items) with a modest pantry.',
    build: () =>
      groceryBody({
        type: 'recipe',
        needed: [
          'ground beef',
          'chicken thighs',
          'corn tortillas',
          'flour tortillas',
          'romaine lettuce',
          'roma tomatoes',
          'white onion',
          'cilantro',
          'limes',
          'avocados',
          'shredded cheddar',
          'cotija cheese',
          'sour cream',
          'black beans',
          'pinto beans',
          'jalapenos',
          'salsa verde',
          'chili powder',
          'cumin',
          'smoked paprika',
          'garlic powder',
          'Mexican rice mix',
          'hot sauce',
          'tortilla chips',
        ].map((display_name) => ({ display_name })),
        pantry: [
          'chili powder',
          'cumin',
          'garlic powder',
          'hot sauce',
          'white onion',
          'limes',
          'salt',
          'olive oil',
        ],
        title: 'Taco Night Spread',
      }),
  },
  {
    feature: 'grocery_generate',
    name: 'leftovers_fried_rice',
    note: "source_type 'leftovers' (use-up meal) with cooked items already on hand.",
    build: () =>
      groceryBody({
        type: 'leftovers',
        needed: [
          { display_name: 'cooked rice', amount_text: '3 cups' },
          { display_name: 'roast chicken', amount_text: '1 cup shredded' },
          { display_name: 'eggs', amount_text: '3' },
          { display_name: 'frozen peas', amount_text: '1/2 cup' },
          { display_name: 'scallions', amount_text: '3' },
          { display_name: 'soy sauce', amount_text: '3 tbsp' },
          { display_name: 'sesame oil', amount_text: '1 tsp' },
        ],
        pantry: ['cooked rice', 'roast chicken', 'eggs', 'soy sauce'],
        title: 'Leftover Chicken Fried Rice',
      }),
  },
  {
    feature: 'grocery_generate',
    name: 'session_without_title',
    note: "source_type 'session' with no recipe_title (category inference from names only).",
    build: () =>
      groceryBody({
        type: 'session',
        needed: [
          { display_name: 'eggs', amount_text: '6' },
          { display_name: 'canned crushed tomatoes', amount_text: '28 oz' },
          { display_name: 'red bell pepper', amount_text: '1' },
          { display_name: 'feta', amount_text: '4 oz' },
          { display_name: 'cumin' },
          { display_name: 'crusty bread' },
          { display_name: 'harissa paste', amount_text: '1 tbsp' },
          { display_name: 'frozen spinach' },
        ],
        pantry: ['cumin', 'olive oil', 'eggs'],
      }),
  },
  {
    feature: 'grocery_generate',
    name: 'pot_pie_frozen_dairy_meat',
    note: 'Mix of frozen, dairy, meat and pantry items with amounts; two covered by the pantry.',
    build: () =>
      groceryBody({
        type: 'recipe',
        needed: [
          { display_name: 'frozen pie crust', amount_text: '2' },
          { display_name: 'frozen mixed vegetables', amount_text: '2 cups' },
          { display_name: 'chicken breast', amount_text: '1 lb' },
          { display_name: 'butter', amount_text: '6 tbsp' },
          { display_name: 'all-purpose flour', amount_text: '1/3 cup' },
          { display_name: 'chicken broth', amount_text: '1 3/4 cups' },
          { display_name: 'heavy cream', amount_text: '1/2 cup' },
          { display_name: 'fresh thyme', amount_text: '4 sprigs' },
        ],
        pantry: ['flour', 'butter', 'black pepper'],
        title: 'Chicken Pot Pie',
      }),
  },
  {
    feature: 'grocery_generate',
    name: 'vegan_curry_plant_based',
    note: 'Plant-based list; checks categories for tofu, curry paste and canned goods.',
    build: () =>
      groceryBody({
        type: 'recipe',
        needed: [
          { display_name: 'extra firm tofu', amount_text: '14 oz' },
          { display_name: 'coconut milk', amount_text: '1 can' },
          { display_name: 'red curry paste', amount_text: '2 tbsp' },
          { display_name: 'baby bok choy', amount_text: '4 heads' },
          { display_name: 'jasmine rice', amount_text: '1.5 cups' },
          { display_name: 'lime', amount_text: '1' },
          { display_name: 'soy sauce', amount_text: '1 tbsp' },
        ],
        pantry: ['jasmine rice', 'red curry paste', 'soy sauce', 'neutral oil'],
        title: 'Tofu Red Curry',
      }),
  },
];

// ---------------------------------------------------------------------------
// pantry_parse (only with --images-dir)
// ---------------------------------------------------------------------------

const PANTRY_IMAGE_MAX_BYTES = 6 * 1024 * 1024;

function toBase64(bytes: Uint8Array): string {
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

/** One request per `.jpg` / `.jpeg` file in `dir` (sorted by name). */
export async function pantryImageFixtures(dir: string): Promise<Fixture[]> {
  const files: string[] = [];
  for await (const entry of Deno.readDir(dir)) {
    if (entry.isFile && /\.jpe?g$/i.test(entry.name)) files.push(entry.name);
  }
  files.sort();
  const fixtures: Fixture[] = [];
  for (const file of files) {
    const bytes = await Deno.readFile(`${dir}/${file}`);
    if (bytes.length > PANTRY_IMAGE_MAX_BYTES) {
      throw new Error(`${file} is ${bytes.length} bytes; pantry-parse accepts up to ~6 MB decoded`);
    }
    const base64 = toBase64(bytes);
    fixtures.push({
      feature: 'pantry_parse',
      name: file.replace(/\.jpe?g$/i, ''),
      note: `Photo ${file} (${bytes.length} bytes).`,
      build: () => ({
        client_request_id: crypto.randomUUID(),
        image_base64: base64,
        image_mime_type: 'image/jpeg',
      }),
    });
  }
  return fixtures;
}

// ---------------------------------------------------------------------------
// Registry + validation
// ---------------------------------------------------------------------------

export const FIXTURES: readonly Fixture[] = [
  ...DINNER_FIXTURES,
  ...SUBSTITUTION_FIXTURES,
  ...REWRITE_FIXTURES,
  ...COOK_TURN_FIXTURES,
  ...IMPORT_FIXTURES,
  ...GROCERY_FIXTURES,
];

const IMPORT_SYNC_MAX_BYTES = 6000;

export interface FixtureCheck {
  feature: FeatureKey;
  name: string;
  errors: string[];
}

/**
 * Parses every fixture body with its endpoint's Zod schema, checks that two
 * builds carry different idempotency ids, and (recipe_import) that the text
 * stays under the sync/async threshold. Returns one entry per fixture.
 */
export function validateFixtures(fixtures: readonly Fixture[]): FixtureCheck[] {
  const encoder = new TextEncoder();
  return fixtures.map((f) => {
    const errors: string[] = [];
    const spec = FEATURES.find((s) => s.key === f.feature);
    try {
      const a = f.build();
      const b = f.build();
      const parsed = REQUEST_SCHEMAS[f.feature].safeParse(a);
      if (!parsed.success) {
        for (const issue of parsed.error.issues) {
          errors.push(`${issue.path.join('.') || '<root>'}: ${issue.message}`);
        }
      }
      if (spec && a[spec.idField] === b[spec.idField]) {
        errors.push(`${spec.idField} is not regenerated per build`);
      }
      if (f.feature === 'recipe_import') {
        const text = (a.payload as { pasted_text?: string }).pasted_text ?? '';
        const bytes = encoder.encode(text).byteLength;
        if (bytes > IMPORT_SYNC_MAX_BYTES) {
          errors.push(`pasted_text is ${bytes} bytes; may be queued async instead of answered`);
        }
      }
    } catch (err) {
      errors.push(`build threw: ${err instanceof Error ? err.message : String(err)}`);
    }
    return { feature: f.feature, name: f.name, errors };
  });
}

if (import.meta.main) {
  const flag = Deno.args.indexOf('--images-dir');
  const imagesDir = flag >= 0 ? Deno.args[flag + 1] : undefined;
  const all = [...FIXTURES, ...(imagesDir ? await pantryImageFixtures(imagesDir) : [])];
  const checks = validateFixtures(all);
  for (const spec of FEATURES) {
    const mine = checks.filter((c) => c.feature === spec.key);
    const bad = mine.filter((c) => c.errors.length > 0);
    console.log(`${spec.key.padEnd(22)} ${mine.length - bad.length}/${mine.length} valid`);
    for (const c of bad) console.log(`  FAIL ${c.name}: ${c.errors.join('; ')}`);
  }
  if (checks.some((c) => c.errors.length > 0)) Deno.exit(1);
}
