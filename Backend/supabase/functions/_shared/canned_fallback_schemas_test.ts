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

Deno.test('validateCannedFallback: pantry_parse with optional parse_quality passes', () => {
  const errors = validateCannedFallback('pantry_parse', {
    items: [{ display_name: 'tomato', confidence: 0.92 }],
    parse_quality: 'high',
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

Deno.test('validateCannedFallback: grocery_generate with reminders_export_url passes', () => {
  const errors = validateCannedFallback('grocery_generate', {
    items: [{ name: 'milk', priority: 'high' }],
    reminders_export_url: 'x-apple-reminderkit://REMCDReminder/abc',
  });
  assertEquals(errors, []);
});

Deno.test('validateCannedFallback: cook_turn requires reply_text', () => {
  const errors = validateCannedFallback('cook_turn', { intent: 'next_step' });
  assert(errors.length > 0);
  assert(errors.some((e) => e.issue.includes('missing required key')));
});
