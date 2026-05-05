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

// Allergen rawValue → ingredient-substring expansion. The bare rawValue
// alone misses real ingredient names ("almond" doesn't contain "tree_nut",
// "groundnut" doesn't contain "peanut"). Plain substring is preserved
// (safety first); the expansion only widens what counts as a hit. Codes
// without an entry here fall back to `[rule.value]` as before.
//
// SAFETY: prefer false positives — a "butternut squash" flagged by a "nut"
// rule retries to a substitution; a missed almond ships an allergen.
// CLAUDE.md: "favor false positives (extra retry) over false negatives".
const ALLERGEN_KEYWORD_EXPANSION: Record<string, string[]> = {
  // Coarse "nut" allergen used by mockup 02's "nut-free" onboarding chip.
  // Covers tree-nut species + peanuts (legume) since the user-facing chip
  // makes no botanical distinction.
  //
  // Bare "nut" is word-boundary-matched (CA2-1 fix — see
  // ALLERGY_WORD_BOUNDARY_NEEDLES) so it catches "mixed nuts" but not
  // coconut / butternut / donut / nutmeg. ALL species names that contain
  // "nut" as a sub-word (walnut, hazelnut, chestnut, peanut) MUST be listed
  // explicitly here — the word-boundary tightening means substring fall-
  // through no longer covers them. Plain-substring needles still hit
  // walnuts / hazelnuts / chestnuts / peanuts (the plurals).
  nut: [
    'nut',
    'nuts',  // plain substring — catches "mixed nuts", "roasted nuts", etc. that the word-boundary "nut" misses.
    'almond', 'cashew', 'pistachio', 'pecan', 'macadamia',
    'walnut', 'hazelnut', 'chestnut', 'peanut', 'groundnut',
    'brazil nut', 'pine nut', 'pignoli',
    'marzipan', 'praline', 'nougat', 'gianduja',
  ],
  // tree_nut: same coverage as `nut` minus peanut (which is a legume).
  // Keeps existing rawValue working — historic Settings selections
  // persist to "tree_nut" and were previously near-non-functional.
  tree_nut: [
    'almond', 'cashew', 'pistachio', 'pecan', 'macadamia',
    'walnut', 'hazelnut', 'chestnut',
    'brazil nut', 'pine nut', 'pignoli',
    'tree nut', 'marzipan', 'praline', 'nougat', 'gianduja',
  ],
  peanut: ['peanut', 'groundnut'],
  // soy: covers tofu / tempeh / edamame / miso / soy sauce that don't
  // contain "soy" as a substring on their own.
  soy: ['soy', 'soya', 'tofu', 'tempeh', 'edamame', 'miso'],
  // shellfish: rawValue alone misses crab / lobster / shrimp etc. The
  // existing FISH_SHELLFISH_KEYWORDS list covers the species; reuse.
  shellfish: [
    'shellfish', 'shrimp', 'prawn', 'lobster', 'crab', 'clam', 'mussel',
    'oyster', 'scallop', 'squid', 'octopus', 'calamari', 'crawfish',
    'crayfish',
  ],
};

/** Allergen rawValue → keywords (rawValue itself if no expansion). */
function allergyKeywordsFor(allergenValue: string): string[] {
  return ALLERGEN_KEYWORD_EXPANSION[allergenValue] ?? [allergenValue];
}

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

// Allergy-side word-boundary exceptions. Almost all allergy needles are
// safety-critical species names ("almond", "shrimp") that MUST keep plain
// substring matching so "almonds" and "shrimp paste" still hit. The narrow
// exception is the bare "nut" trigram from the `nut` allergen-rawValue
// expansion — plain substring matched coconut / butternut squash / donut /
// nutmeg, creating retry-amplification on benign foods (CA2-1 / CA1-H4 /
// DB1-2). Word-boundary on "nut" specifically still matches plain "nut" /
// "nuts" (mixed nuts dish) but not the compound benign foods. Species-level
// nut names (walnut/hazelnut/chestnut/peanut) are added explicitly to the
// `nut` expansion so the safety bar is unchanged.
const ALLERGY_WORD_BOUNDARY_NEEDLES: ReadonlySet<string> = new Set([
  'nut',
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

/** Unconditional word-boundary regex match. Callers gate which needles
 *  get this treatment (DIET path: WORD_BOUNDARY_KEYWORDS;
 *  ALLERGY path: ALLERGY_WORD_BOUNDARY_NEEDLES). */
function matchesNeedleBoundary(haystack: string, needle: string): boolean {
  const escaped = needle.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const re = new RegExp(`(?<![a-z0-9])${escaped}(?![a-z0-9])`, 'i');
  return re.test(haystack);
}

/** DIET-path lookup: word-boundary only for WORD_BOUNDARY_KEYWORDS, else plain. */
function matchesNeedleDiet(haystack: string, needle: string): boolean {
  if (WORD_BOUNDARY_KEYWORDS.has(needle)) {
    return matchesNeedleBoundary(haystack, needle);
  }
  return haystack.includes(needle);
}

/**
 * Allergy + dislike use plain substring for almost every needle (safety first
 * — "almond" must match "almonds" / "almond extract"). The narrow exception
 * is needles listed in ALLERGY_WORD_BOUNDARY_NEEDLES — currently just the
 * bare "nut" trigram, which would otherwise false-positive on coconut /
 * butternut / donut / nutmeg. Species-level needles in the same expansion
 * list keep plain substring matching.
 */
function containsAnyStrict(haystack: string, needles: string[]): string | null {
  const lower = haystack.toLowerCase();
  for (const n of needles) {
    const hit = ALLERGY_WORD_BOUNDARY_NEEDLES.has(n)
      ? matchesNeedleBoundary(lower, n)
      : matchesNeedlePlain(lower, n);
    if (hit) return n;
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
    if (matchesNeedleDiet(lower, n)) return n;
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
        // Plain substring on the expanded keyword set: safety-critical,
        // better to retry on a false positive than ship a hidden
        // allergen. `allergyKeywordsFor` widens coarse allergen rawValues
        // (e.g. "nut", "tree_nut", "shellfish") into species-level lists.
        const hit = containsAnyStrict(text, allergyKeywordsFor(value));
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

// ---------------------------------------------------------------------------
// validateSubstitution — step 4 entry point
// ---------------------------------------------------------------------------
//
// The substitution endpoint gets a single free-text suggestion from Gemini
// (substitution_text + reasoning + amount_conversion). We don't get a
// structured ingredient list, so the validator scans the combined text
// against the same keyword tables validateDish uses.
//
// Same safety bias: allergies run on plain-substring match, diets run with
// word-boundary + exceptions. The suggestion TEXT is free-form, so we have
// no "display_name" to check against MULTI_WORD_DIET_EXCEPTIONS (that
// exception list filters by exact lowercased display_name match — no
// substring safe anchor exists in a suggestion blob). In practice the
// substitution suggestions are short and narrow — "use cashew milk" not
// "a milk thistle infusion" — so the ambiguity window is tiny.
//
// Equipment check: if the model proposed a workaround that mentions
// equipment the household doesn't have (available_equipment list), flag.
// The user's "broken equipment" is expected to be absent from
// available_equipment already; iOS strips it before sending.

export interface SubstitutionCandidate {
  substitution_text: string;
  reasoning: string;
  amount_conversion?: string | null;
  constraint_safe: boolean;
}

export interface SubstitutionContext {
  dietaryRules: DietaryRule[];
  availableEquipment: string[];
  /** Equipment the model should additionally avoid (e.g. derived from
   *  user_problem "blender broke"). Union'd with unavailable. */
  avoidEquipment?: string[];
}

export function validateSubstitution(
  sub: SubstitutionCandidate,
  ctx: SubstitutionContext,
): ValidationResult {
  const issues: ValidationIssue[] = [];

  const combined = [
    sub.substitution_text,
    sub.reasoning,
    sub.amount_conversion ?? '',
  ].join(' ').toLowerCase();

  // 1. Allergy + hard dislike + diet: keyword match on the combined text.
  // Allergy uses plain substring (safety first); dislike likewise;
  // diet uses word-boundary to avoid false positives on compound words.
  const hardDietary = ctx.dietaryRules.filter((r) => r.severity === 'hard');
  for (const rule of hardDietary) {
    const value = rule.value.toLowerCase().trim();
    if (!value) continue;

    if (rule.kind === 'allergy') {
      // Same expansion as validateDish — coarse rawValues like "nut"
      // expand to a species list so the substitution validator can't
      // miss what the dish validator catches.
      const hit = containsAnyStrict(combined, allergyKeywordsFor(value));
      if (hit) {
        issues.push({ kind: 'allergen', value: rule.value, ingredient: sub.substitution_text });
      }
      continue;
    }

    if (rule.kind === 'dislike') {
      const hit = containsAnyStrict(combined, [value]);
      if (hit) {
        issues.push({ kind: 'dislike_hard', value: rule.value, ingredient: sub.substitution_text });
      }
      continue;
    }

    if (rule.kind === 'diet') {
      const keywords = dietKeywordsFor(value);
      if (keywords) {
        for (const n of keywords) {
          if (matchesNeedleDiet(combined, n)) {
            issues.push({
              kind: 'diet_violation',
              diet: rule.value,
              ingredient: sub.substitution_text,
              keyword: n,
            });
            break; // one violation per rule is enough — retry will fix all
          }
        }
      }
    }
  }

  // 2. Unavailable / avoid equipment implied by the suggestion.
  const unavailable = new Set<string>();
  for (const eqKey of Object.keys(EQUIPMENT_IMPLICATION)) {
    if (!ctx.availableEquipment.includes(eqKey)) unavailable.add(eqKey);
  }
  for (const avoid of ctx.avoidEquipment ?? []) unavailable.add(avoid);
  for (const eqKey of unavailable) {
    const needles = EQUIPMENT_IMPLICATION[eqKey];
    if (!needles) continue;
    const hit = containsAnyStrict(combined, needles);
    if (hit) issues.push({ kind: 'unavailable_equipment_implied', keyword: hit });
  }

  // 3. Model claimed constraint_safe=true but we found real issues.
  if (sub.constraint_safe && issues.length > 0) {
    issues.push({ kind: 'claims_pass_falsely' });
  }

  return { valid: issues.length === 0, issues };
}

/**
 * Compose a compact human-readable violation summary to amplify the retry
 * prompt. The model gets "RE-VIOLATED: <summary>" prepended to the system
 * prompt on retry, so it understands what to avoid without us re-sending
 * the entire ruleset. Emits PII-free labels — no user text quoted back.
 */
export function summarizeViolations(result: ValidationResult): string {
  if (result.valid) return '';
  const kinds = new Set<string>();
  const allergens = new Set<string>();
  const diets = new Set<string>();
  const equipment = new Set<string>();
  for (const issue of result.issues) {
    kinds.add(issue.kind);
    if (issue.kind === 'allergen') allergens.add(issue.value);
    if (issue.kind === 'diet_violation') diets.add(issue.diet);
    if (issue.kind === 'unavailable_equipment_implied') equipment.add(issue.keyword);
  }
  const parts: string[] = [];
  if (allergens.size) parts.push(`allergens=${[...allergens].join('|')}`);
  if (diets.size) parts.push(`diets=${[...diets].join('|')}`);
  if (equipment.size) parts.push(`unavailable_equipment=${[...equipment].join('|')}`);
  if (!parts.length) parts.push(`kinds=${[...kinds].join('|')}`);
  return parts.join('; ');
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
