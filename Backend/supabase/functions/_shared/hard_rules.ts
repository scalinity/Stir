// Hard-rule validator for Gemini output.
//
// Runs AFTER schema validation and BEFORE we commit output to the user.
// Violations force a retry; persistent violations surface as AI-02.
//
// Validators live here so the standalone substitution endpoint and the
// Live function-call round-trip (step 6) can share the same rules.
// CLAUDE.md §Invariants: "Hard-rule validator runs on every substitution
// output, regardless of invocation path."
//
// Scope for step 3:
//   - dinner_solve dishes: dietary-rule match on ingredients, time budget
//     enforcement, available_equipment consistency.
//   - pantry_parse output: JSON-schema + confidence enum check (see
//     pantry-parse handler; structural-only).
//
// Dietary keyword lists are conservative: favor false positives (extra
// retry) over false negatives (ship an allergen). Later steps expand
// via the IngredientCanonical ontology.

export type DietaryRuleKind = 'allergy' | 'diet' | 'dislike' | 'goal';
export type DietaryRuleSeverity = 'hard' | 'soft';

export interface DietaryRule {
  kind: DietaryRuleKind;
  value: string;           // free text, e.g. "peanut", "vegetarian", "low-sodium"
  severity: DietaryRuleSeverity;
}

export interface DishIngredient {
  display_name: string;
  canonical_slug?: string | null;
  amount_text?: string;
  is_optional?: boolean;
}

export interface DishStep {
  step_number: number;
  instruction_text: string;
  timer_seconds?: number | null;
  caution_tags?: string[];
}

export interface DishRecipePlan {
  servings: number;
  difficulty: number;
  cuisine?: string | null;
  ingredients: DishIngredient[];
  steps: DishStep[];
}

export interface CandidateDish {
  rank: number;
  title: string;
  total_time_minutes: number;
  why_it_fits: string;
  missing_ingredient_count: number;
  fit_label_primary: string;
  fit_label_secondary?: string | null;
  hard_constraint_pass: boolean;
  recipe_plan: DishRecipePlan;
  reasoning_summary: string;
}

export interface DishContext {
  dietaryRules: DietaryRule[];
  availableEquipment: string[];
  maxTimeMinutes?: number;
  avoidEquipment?: string[];
}

export type ValidationIssue =
  | { kind: 'allergen'; value: string; ingredient: string }
  | { kind: 'diet_violation'; diet: string; ingredient: string; keyword: string }
  | { kind: 'dislike_hard'; value: string; ingredient: string }
  | { kind: 'time_over_budget'; actual: number; max: number }
  | { kind: 'unavailable_equipment_implied'; keyword: string }
  | { kind: 'claims_pass_falsely' };

export interface ValidationResult {
  valid: boolean;
  issues: ValidationIssue[];
}

// ---------------------------------------------------------------------------
// Diet keyword tables (conservative; step-3 MVP)
// ---------------------------------------------------------------------------
// Normalized to lowercase + trimmed; match against ingredient display_name
// AND canonical_slug via substring. A single keyword match fires a violation.

const MEAT_KEYWORDS = [
  'beef', 'steak', 'chicken', 'pork', 'bacon', 'sausage', 'ham', 'lamb',
  'turkey', 'duck', 'veal', 'goat', 'rabbit', 'pepperoni', 'salami',
  'prosciutto', 'chorizo', 'bratwurst', 'venison', 'bison',
];

const FISH_SHELLFISH_KEYWORDS = [
  'fish', 'salmon', 'tuna', 'cod', 'halibut', 'trout', 'mackerel', 'sardine',
  'anchovy', 'shrimp', 'prawn', 'lobster', 'crab', 'clam', 'mussel', 'oyster',
  'scallop', 'squid', 'octopus', 'calamari',
];

const DAIRY_KEYWORDS = [
  'milk', 'cream', 'butter', 'cheese', 'yogurt', 'yoghurt', 'ghee',
  'whey', 'casein', 'parmesan', 'mozzarella', 'cheddar', 'feta', 'ricotta',
  'kefir', 'buttermilk',
];

const EGG_KEYWORDS = ['egg', 'eggs'];

const HONEY_KEYWORDS = ['honey'];

// Equipment keyword map: equipment name → substrings that imply needing it
// in a recipe step. Step-3 is conservative — we only flag the obvious.
const EQUIPMENT_IMPLICATION: Record<string, string[]> = {
  sous_vide: ['sous vide', 'immersion circulator'],
  pressure_cooker: ['pressure cooker', 'instant pot'],
  air_fryer: ['air fryer'],
  stand_mixer: ['stand mixer'],
  food_processor: ['food processor'],
  blender: ['blender'],
  grill: ['grill', 'grilling', 'barbecue', 'bbq'],
  wok: ['wok'],
  dutch_oven: ['dutch oven'],
};

// Short, ambiguous keywords in the DIET lists that would substring-match
// compound words: "egg" in eggplant, "butter" in butternut, "wheat" in
// buckwheat/wheatgrass. For diet-rule matching only, require ASCII word
// boundaries so these don't false-positive on legitimate plant names.
//
// Allergy + dislike rules deliberately keep plain substring matching —
// safety-critical, prefer extra retries over ever missing an allergen.
// CLAUDE.md: "favor false positives (extra retry) over false negatives
// (ship an allergen)."
const WORD_BOUNDARY_KEYWORDS: ReadonlySet<string> = new Set([
  'egg', 'eggs', 'butter', 'milk', 'wheat', 'ham', 'cream',
]);

// Exact multi-word ingredient names where a diet-keyword substring is
// semantically wrong (mushrooms named after animals, herbs named after
// dairy). Diet-rule matching bails out before the keyword scan if the
// whole (trimmed, lowercased) display_name matches one of these.
const MULTI_WORD_DIET_EXCEPTIONS: ReadonlySet<string> = new Set([
  'chicken of the woods',
  'chicken-of-the-woods',
  'hen of the woods',
  'hen-of-the-woods',
  'milk thistle',
  'milk-thistle',
]);

function matchesNeedlePlain(haystack: string, needle: string): boolean {
  return haystack.includes(needle);
}

function matchesNeedleWordBoundary(haystack: string, needle: string): boolean {
  if (WORD_BOUNDARY_KEYWORDS.has(needle)) {
    const escaped = needle.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const re = new RegExp(`(?<![a-z0-9])${escaped}(?![a-z0-9])`, 'i');
    return re.test(haystack);
  }
  return haystack.includes(needle);
}

/** Allergy + dislike use plain substring (safety first). */
function containsAnyStrict(haystack: string, needles: string[]): string | null {
  const lower = haystack.toLowerCase();
  for (const n of needles) {
    if (matchesNeedlePlain(lower, n)) return n;
  }
  return null;
}

/** Diet checks use word-boundary + ingredient-name exceptions. */
function containsDietKeyword(
  displayName: string,
  ingredientText: string,
  needles: string[],
): string | null {
  const trimmedDisplay = displayName.toLowerCase().trim();
  if (MULTI_WORD_DIET_EXCEPTIONS.has(trimmedDisplay)) return null;
  const lower = ingredientText.toLowerCase();
  for (const n of needles) {
    if (matchesNeedleWordBoundary(lower, n)) return n;
  }
  return null;
}

function ingredientText(ing: DishIngredient): string {
  return `${ing.display_name} ${ing.canonical_slug ?? ''}`;
}

// ---------------------------------------------------------------------------
// validateDish — the main entry point
// ---------------------------------------------------------------------------

export function validateDish(dish: CandidateDish, ctx: DishContext): ValidationResult {
  const issues: ValidationIssue[] = [];

  // 1. Allergy + hard dislike + diet: keyword match on ingredient text.
  // SAFETY: allergy rules run against optional ingredients too — an
  // allergen is unsafe even if the recipe marks it "to taste". Dislike
  // and diet rules skip optionals (user can omit safely).
  const hardDietary = ctx.dietaryRules.filter((r) => r.severity === 'hard');
  for (const ing of dish.recipe_plan.ingredients) {
    const text = ingredientText(ing);
    for (const rule of hardDietary) {
      const value = rule.value.toLowerCase().trim();
      if (!value) continue;

      if (rule.kind === 'allergy') {
        // Runs even for is_optional — allergens are never safe.
        // Plain substring: safety-critical, better to retry on a false
        // positive than ship a hidden allergen.
        const hit = containsAnyStrict(text, [value]);
        if (hit) issues.push({ kind: 'allergen', value: rule.value, ingredient: ing.display_name });
        continue;
      }

      // Dislikes + diets: skip optional ingredients; user can omit them.
      if (ing.is_optional) continue;

      if (rule.kind === 'dislike') {
        const hit = containsAnyStrict(text, [value]);
        if (hit) issues.push({ kind: 'dislike_hard', value: rule.value, ingredient: ing.display_name });
      }

      if (rule.kind === 'diet') {
        const keywords = dietKeywordsFor(value);
        if (keywords) {
          const hit = containsDietKeyword(ing.display_name, text, keywords);
          if (hit) issues.push({ kind: 'diet_violation', diet: rule.value, ingredient: ing.display_name, keyword: hit });
        }
      }
    }
  }

  // 2. Time budget.
  if (ctx.maxTimeMinutes !== undefined && dish.total_time_minutes > ctx.maxTimeMinutes) {
    issues.push({
      kind: 'time_over_budget',
      actual: dish.total_time_minutes,
      max: ctx.maxTimeMinutes,
    });
  }

  // 3. Unavailable / avoid equipment implied by step text.
  const unavailable = new Set<string>();
  for (const eqKey of Object.keys(EQUIPMENT_IMPLICATION)) {
    if (!ctx.availableEquipment.includes(eqKey)) unavailable.add(eqKey);
  }
  for (const avoid of ctx.avoidEquipment ?? []) {
    unavailable.add(avoid);
  }
  const stepText = dish.recipe_plan.steps.map((s) => s.instruction_text).join(' ').toLowerCase();
  for (const eqKey of unavailable) {
    const needles = EQUIPMENT_IMPLICATION[eqKey];
    if (!needles) continue;
    const hit = containsAnyStrict(stepText, needles);
    if (hit) issues.push({ kind: 'unavailable_equipment_implied', keyword: hit });
  }

  // 4. Model falsely claimed hard_constraint_pass.
  if (dish.hard_constraint_pass && issues.length > 0) {
    issues.push({ kind: 'claims_pass_falsely' });
  }

  return { valid: issues.length === 0, issues };
}

function dietKeywordsFor(dietValue: string): string[] | null {
  const v = dietValue.toLowerCase().replace(/\s+/g, '_').trim();
  switch (v) {
    case 'vegetarian':
      return [...MEAT_KEYWORDS, ...FISH_SHELLFISH_KEYWORDS];
    case 'pescatarian':
      return MEAT_KEYWORDS;
    case 'vegan':
      return [
        ...MEAT_KEYWORDS,
        ...FISH_SHELLFISH_KEYWORDS,
        ...DAIRY_KEYWORDS,
        ...EGG_KEYWORDS,
        ...HONEY_KEYWORDS,
      ];
    case 'dairy_free':
    case 'dairy-free':
    case 'lactose_free':
    case 'lactose-free':
      return DAIRY_KEYWORDS;
    case 'gluten_free':
    case 'gluten-free':
      // 'flour', 'pasta', 'noodle', 'bread' are deliberately NOT here —
      // buckwheat flour, rice noodles, almond flour, etc. are all
      // gluten-free and would false-positive. 'wheat' + 'barley' + 'rye'
      // cover the actual gluten grains; 'soy sauce' catches the common
      // wheat-containing condiment.
      return ['wheat', 'barley', 'rye', 'soy sauce', 'seitan'];
    default:
      return null; // unknown diet → no automated keyword check
  }
}
