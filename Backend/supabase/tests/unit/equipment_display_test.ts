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

Deno.test(
  'equipmentDisplayNames: slugs equal to Object.prototype member names do not leak inherited functions',
  () => {
    // SCA-423 follow-up. Earlier the table was a frozen object literal,
    // so `M['toString']` resolved to Object.prototype.toString (a
    // truthy function), the `??` short-circuit was never reached, and
    // the function reference flowed into the rendered prompt (where
    // JSON.stringify silently rendered it as `null`). With the Map
    // backing, `.get('toString')` returns undefined → fallback fires →
    // we get a string back.
    // Exact return values don't matter (the fallback does underscore
    // collapse, so e.g. `__proto__` → `  proto  `). What matters is
    // that the helper returns *strings*, not Function references that
    // would render to `null` after JSON.stringify in renderPrompt.
    const inheritedMemberNames = [
      'toString',
      'constructor',
      'hasOwnProperty',
      'valueOf',
      'isPrototypeOf',
      'propertyIsEnumerable',
      '__proto__',
    ];
    const result = equipmentDisplayNames(inheritedMemberNames);
    assertEquals(result.length, inheritedMemberNames.length);
    for (const v of result) {
      if (typeof v !== 'string') {
        throw new Error(`Expected string, got ${typeof v}: ${String(v)}`);
      }
    }
    // Spot-check the common-case names round-trip through the fallback
    // (single-token, no leading/trailing underscores) unchanged.
    assertEquals(
      equipmentDisplayNames(['toString', 'constructor', 'valueOf']),
      ['toString', 'constructor', 'valueOf'],
    );
  },
);

Deno.test('EQUIPMENT_DISPLAY_NAMES covers every iOS CommonCode rawValue', () => {
  // Mirrors `KitchenEquipment.CommonCode` in
  // Stir/Core/Models/KitchenEquipment+Extensions.swift. If iOS adds a
  // new case, this test fails until the backend map is updated — and
  // the fallback in equipmentDisplayNames keeps prod safe in the
  // meantime.
  //
  // The value-shape regex catches typos that leave a slug-style value
  // in the table (e.g. `nonstick_pan: 'nonstick_pan'` or
  // `nonstick_pan: 'nonstick pan2'`). Underscores, digits, and
  // punctuation in display strings would re-create the very bug this
  // mirror exists to prevent.
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
  const wellFormed = /^[A-Za-z]+( [A-Za-z]+)*$/;
  for (const slug of iosRawValues) {
    const display = EQUIPMENT_DISPLAY_NAMES.get(slug);
    if (display === undefined) {
      throw new Error(`Missing display name for iOS slug "${slug}"`);
    }
    if (!wellFormed.test(display)) {
      throw new Error(
        `Display name for "${slug}" is malformed: "${display}" — must be ASCII letters and single spaces only`,
      );
    }
  }
});
