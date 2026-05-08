// SCA-81 — unit coverage for the canned_fallback shape validator.
// Pure-function tests; no Postgres or edge runtime dependency.

import { assert, assertEquals } from '@std/assert';
import { validateCannedFallback } from './canned_fallback_schemas.ts';

Deno.test('validateCannedFallback: dinner_solve { events: [...] } passes', () => {
  const errors = validateCannedFallback('dinner_solve', {
    events: [{ kind: 'card', dish_id: 'abc' }],
  });
  assertEquals(errors, []);
});

Deno.test('validateCannedFallback: substitution { suggestion, why } passes', () => {
  const errors = validateCannedFallback('substitution', {
    suggestion: 'Use butter instead of olive oil',
    why: 'Pantry has butter; works for sautéing',
  });
  assertEquals(errors, []);
});

Deno.test('validateCannedFallback: rejects substitution shape pasted into dinner_solve row', () => {
  const errors = validateCannedFallback('dinner_solve', {
    suggestion: 'wrong shape — substitution payload',
    why: 'admin paste error',
  });
  assert(errors.length > 0);
  assert(errors.some((e) => e.issue.includes('unknown top-level key')));
  assert(errors.some((e) => e.field.startsWith('canned_fallback_json.')));
});

Deno.test('validateCannedFallback: rejects empty payload (no required key)', () => {
  const errors = validateCannedFallback('substitution', {});
  assert(errors.length > 0);
  assert(errors.some((e) => e.issue.includes('missing required key')));
});

Deno.test('validateCannedFallback: rejects unknown feature_key', () => {
  const errors = validateCannedFallback('made_up_feature', { items: [] });
  assertEquals(errors.length, 1);
  assertEquals(errors[0]!.field, 'feature_key');
  assert(errors[0]!.issue.includes('unknown feature_key'));
});

Deno.test('validateCannedFallback: cook_mode_realtime is unsupported (live audio)', () => {
  const errors = validateCannedFallback('cook_mode_realtime', { reply_text: 'anything' });
  assertEquals(errors.length, 1);
  assert(errors[0]!.issue.includes('does not support canned fallbacks'));
});

Deno.test('validateCannedFallback: pantry_parse with full wire shape passes', () => {
  const errors = validateCannedFallback('pantry_parse', {
    parse_id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
    ingredients: [{ display_name: 'tomato', confidence: 'high' }],
    overall_confidence: 0.92,
    prompt_version: '1.0.0',
    latency_ms: 1200,
    retry_count: 0,
  });
  assertEquals(errors, []);
});

Deno.test('validateCannedFallback: pantry_parse with empty-pantry result passes', () => {
  // ingredients[] empty is legal (empty pantry); parse_id is the
  // anchor key.
  const errors = validateCannedFallback('pantry_parse', {
    parse_id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
    ingredients: [],
    overall_confidence: 1.0,
    prompt_version: '1.0.0',
    latency_ms: 800,
    retry_count: 0,
  });
  assertEquals(errors, []);
});

Deno.test('validateCannedFallback: recipe_import with status=queued passes', () => {
  const errors = validateCannedFallback('recipe_import', {
    import_id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
    status: 'queued',
  });
  assertEquals(errors, []);
});

Deno.test('validateCannedFallback: grocery_generate with full wire shape passes', () => {
  const errors = validateCannedFallback('grocery_generate', {
    source_id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
    source_type: 'recipe',
    missing_items: [{ display_name: 'milk', priority: 'high' }],
    already_have: [{ display_name: 'butter' }],
    total_item_count: 5,
    prompt_version: '1.0.0',
    retry_count: 0,
  });
  assertEquals(errors, []);
});

Deno.test('validateCannedFallback: cook_turn requires spoken_response', () => {
  // suggested_action without spoken_response is incomplete on the wire.
  const errors = validateCannedFallback('cook_turn', { suggested_action: 'advance_step' });
  assert(errors.length > 0);
  assert(errors.some((e) => e.issue.includes('missing required key')));
});

Deno.test('validateCannedFallback: cook_turn full wire shape passes', () => {
  const errors = validateCannedFallback('cook_turn', {
    spoken_response: 'Next step: chop the onions.',
    suggested_action: 'advance_step',
    action_params: null,
    prompt_version: '1.0.0',
    latency_ms: 800,
    retry_count: 0,
  });
  assertEquals(errors, []);
});
