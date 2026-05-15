// Slug → human display-name map for the `KitchenEquipment.CommonCode`
// vocabulary that iOS sends in `household_context.available_equipment`.
//
// Mirror of `Stir/Core/Models/KitchenEquipment+Extensions.swift`
// `CommonCode.displayName`. Swift remains source of truth; this is a
// backend mirror used to keep raw snake_case slugs out of model-facing
// prompt context. SCA-423: without this, "Available equipment:
// {{equipment_json}}" rendered "food_processor" into the system
// instruction and the model copied the literal slug into recipe step
// prose ("In the food_processor, pulse flour…").
//
// The validator (`hard_rules.ts`) still consumes raw slugs — display
// conversion is for prompt rendering only.
//
// Implementation note: backed by a `Map` (not a frozen object literal)
// so that a slug equal to an inherited Object.prototype member name —
// `toString`, `constructor`, `hasOwnProperty`, `valueOf`, etc. —
// resolves to `undefined` via `.get()` and falls through to the
// underscores-to-spaces fallback, rather than returning the inherited
// function reference and silently emitting `null` into the rendered
// JSON. The Zod validator only constrains length (1..64 chars), so
// nothing prevents a buggy or malicious iOS payload from sending
// those literals.

export const EQUIPMENT_DISPLAY_NAMES: ReadonlyMap<string, string> = new Map([
  ['oven', 'oven'],
  ['stovetop', 'stovetop'],
  ['microwave', 'microwave'],
  ['air_fryer', 'air fryer'],
  ['instant_pot', 'Instant Pot'],
  ['slow_cooker', 'slow cooker'],
  ['blender', 'blender'],
  ['food_processor', 'food processor'],
  ['stand_mixer', 'stand mixer'],
  ['rice_cooker', 'rice cooker'],
  ['grill', 'grill'],
  ['griddle', 'griddle'],
  ['cast_iron', 'cast iron pan'],
  ['nonstick_pan', 'nonstick pan'],
  ['sheet_pan', 'sheet pan'],
  ['dutch_oven', 'Dutch oven'],
  ['skillet', 'skillet'],
]);

// Map an array of equipment slugs to display names. Unknown slugs fall
// back to underscores-to-spaces so a newly added Swift enum case can't
// regress the model into emitting `slug_with_underscores` while we
// catch up here.
export function equipmentDisplayNames(slugs: readonly string[]): string[] {
  return slugs.map((slug) => EQUIPMENT_DISPLAY_NAMES.get(slug) ?? slug.replace(/_/g, ' '));
}
