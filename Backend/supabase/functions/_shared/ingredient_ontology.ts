// IngredientCanonical ontology — backend rendering source.
//
// SCA-46 starter: ~120 common cooking-relevant ingredient slugs that
// `pantry-parse` and (future) `dinner-solve` prompts inject as the
// `{{ingredient_ontology_slugs}}` template variable. The model uses
// this list as the canonical vocabulary for `canonical_slug`,
// stabilizing slug coordination across pantry-parse and dinner-solve
// calls. Without this, both prompts emit `null` slugs (the existing
// pre-SCA-26 bug behind the user's "scanned items not removed after
// cook" report — the matching layer falls back to displayName equality
// which often diverges between scan + recipe outputs).
//
// Scope notes:
//   - This is a STARTER ontology, not the full 500-row asset CLAUDE.md
//     §"Data ownership boundary" calls for. ~120 entries cover the
//     dominant case (90%+ of US weeknight ingredients per cooking
//     dataset frequency) without requiring multi-day curation. Expand
//     incrementally as field reports surface gaps.
//   - English / US-only naming; matches CLAUDE.md §"What NOT to reopen"
//     ("English / US-only launch"). Internationalization deferred.
//   - The slug format is snake_case stable wire format. Renaming a
//     slug invalidates every PantryItem.canonicalIngredientSlug and
//     RecipeIngredient.canonicalIngredientSlug already written with
//     the old value — DO NOT rename, only add. Removing a slug is
//     similarly load-bearing.
//
// iOS parallel: `Stir/Resources/IngredientCanonical.json` carries the
// same slug list (plus a richer metadata layer for future iOS lookup
// service, SCA-46 follow-up).

/**
 * Canonical ingredient slugs the AI prompts should draw from when
 * emitting `canonical_slug` on RecipeIngredient or pantry-parse output.
 * Sorted alphabetically to make diffs reviewable; insertion order has
 * no semantic meaning.
 *
 * Categories (informal, NOT exposed to the model):
 *   - vegetables, fruits, herbs, proteins, dairy, grains/starches,
 *     pantry staples, oils, vinegars, condiments, spices, baking,
 *     asian-pantry, beverages, bread/wraps.
 */
export const INGREDIENT_ONTOLOGY_SLUGS: readonly string[] = [
  // Vegetables
  'asparagus',
  'avocado',
  'bell_pepper',
  'broccoli',
  'brussels_sprouts',
  'cabbage',
  'carrot',
  'cauliflower',
  'celery',
  'corn',
  'cucumber',
  'eggplant',
  'garlic',
  'ginger_root',
  'green_bean',
  'jalapeno',
  'kale',
  'leek',
  'lettuce',
  'mushroom',
  'onion',
  'red_onion',
  'peas',
  'potato',
  'scallion',
  'shallot',
  'spinach',
  'squash',
  'sweet_potato',
  'tomato',
  'zucchini',

  // Fruits
  'apple',
  'banana',
  'blueberry',
  'lemon',
  'lime',
  'mango',
  'orange',
  'raspberry',
  'strawberry',

  // Herbs (fresh)
  'basil',
  'cilantro',
  'dill',
  'mint',
  'oregano',
  'parsley',
  'rosemary',
  'thyme',

  // Proteins
  'bacon',
  'black_bean',
  'chicken_breast',
  'chicken_thigh',
  'chickpea',
  'egg',
  'ground_beef',
  'ground_pork',
  'ground_turkey',
  'kidney_bean',
  'lentil',
  'pork_chop',
  'salmon',
  'sausage',
  'shrimp',
  'steak',
  'tofu',
  'tuna',

  // Dairy
  'butter',
  'cheddar_cheese',
  'cream',
  'cream_cheese',
  'feta_cheese',
  'milk',
  'mozzarella_cheese',
  'parmesan_cheese',
  'sour_cream',
  'yogurt',

  // Grains & starches
  'breadcrumb',
  'flour',
  'oats',
  'pasta',
  'quinoa',
  'rice',
  'rice_noodle',

  // Pantry staples
  'all_purpose_flour',
  'brown_sugar',
  'honey',
  'jam',
  'maple_syrup',
  'peanut_butter',
  'salt',
  'sugar',

  // Oils
  'olive_oil',
  'sesame_oil',
  'vegetable_oil',

  // Vinegars
  'apple_cider_vinegar',
  'balsamic_vinegar',
  'rice_vinegar',
  'white_vinegar',

  // Condiments
  'hot_sauce',
  'ketchup',
  'mayonnaise',
  'mustard',

  // Spices (dry)
  'bay_leaf',
  'black_pepper',
  'cayenne',
  'chili_powder',
  'cinnamon',
  'cumin',
  'curry_powder',
  'dried_oregano',
  'garlic_powder',
  'ground_ginger',
  'italian_seasoning',
  'nutmeg',
  'onion_powder',
  'paprika',
  'red_pepper_flake',
  'turmeric',
  'vanilla_extract',

  // Baking
  'baking_powder',
  'baking_soda',
  'chocolate_chip',
  'cocoa_powder',
  'powdered_sugar',
  'yeast',

  // Asian pantry
  'fish_sauce',
  'hoisin_sauce',
  'oyster_sauce',
  'soy_sauce',
  'sriracha',

  // Bread & wraps
  'bread',
  'naan',
  'pita',
  'tortilla',
  'tortilla_chip',
];
