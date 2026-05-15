// SCA-423 — unit tests for the slug → display-name mirror used by every
// AI-prompt render site that injects `available_equipment`.
//
// Without this mapping, "Available equipment: {{equipment_json}}" feeds
// the model a snake_case slug like `food_processor`, and Gemini copies
// the literal slug into recipe step prose ("In the food_processor,
// pulse flour…"). The mirror keeps the validator path (which expects
// slugs) untouched; only prompt rendering converts.

import { assertEquals } from '@std/assert';
import {
  EQUIPMENT_DISPLAY_NAMES,
  equipmentDisplayNames,
} from '../../functions/_shared/equipment_display.ts';

Deno.test('equipmentDisplayNames: known slugs map to human strings', () => {
  assertEquals(
    equipmentDisplayNames([
      'food_processor',
      'air_fryer',
      'instant_pot',
      'dutch_oven',
      'stovetop',
    ]),
    ['food processor', 'air fryer', 'Instant Pot', 'Dutch oven', 'stovetop'],
  );
});

Deno.test('equipmentDisplayNames: unknown slug falls back to underscores-to-spaces', () => {
  // A future Swift enum case (e.g. `pressure_cooker`) that lands before
  // the backend mirror is updated must still render as "pressure
  // cooker", never as the raw slug.
  assertEquals(
    equipmentDisplayNames(['pressure_cooker', 'sous_vide_immersion']),
    ['pressure cooker', 'sous vide immersion'],
  );
});

Deno.test('equipmentDisplayNames: empty array passes through', () => {
  assertEquals(equipmentDisplayNames([]), []);
});

Deno.test('equipmentDisplayNames: order is preserved', () => {
  assertEquals(
    equipmentDisplayNames(['skillet', 'oven', 'blender']),
    ['skillet', 'oven', 'blender'],
  );
});

Deno.test('EQUIPMENT_DISPLAY_NAMES covers every iOS CommonCode rawValue', () => {
  // Mirrors `KitchenEquipment.CommonCode` in
  // Stir/Core/Models/KitchenEquipment+Extensions.swift. If iOS adds a
  // new case, this test fails until the backend map is updated — and
  // the fallback in equipmentDisplayNames keeps prod safe in the
  // meantime.
  const iosRawValues = [
    'oven',
    'stovetop',
    'microwave',
    'air_fryer',
    'instant_pot',
    'slow_cooker',
    'blender',
    'food_processor',
    'stand_mixer',
    'rice_cooker',
    'grill',
    'griddle',
    'cast_iron',
    'nonstick_pan',
    'sheet_pan',
    'dutch_oven',
    'skillet',
  ];
  for (const slug of iosRawValues) {
    if (EQUIPMENT_DISPLAY_NAMES[slug] === undefined) {
      throw new Error(`Missing display name for iOS slug "${slug}"`);
    }
  }
});
