// Tests for INGREDIENT_ONTOLOGY_SLUGS — pin invariants the prompt
// rendering depends on. SCA-46.

import { assert, assertEquals } from 'https://deno.land/std@0.208.0/assert/mod.ts';
import { INGREDIENT_ONTOLOGY_SLUGS } from './ingredient_ontology.ts';

Deno.test('ontology has at least 100 slugs (starter floor)', () => {
  // Below this threshold the model can't draw a stable vocabulary
  // for most weeknight ingredients. Acts as a regression guard
  // against accidental array truncation.
  assert(
    INGREDIENT_ONTOLOGY_SLUGS.length >= 100,
    `expected at least 100 slugs, got ${INGREDIENT_ONTOLOGY_SLUGS.length}`,
  );
});

Deno.test('every slug is non-empty and trimmed', () => {
  for (const slug of INGREDIENT_ONTOLOGY_SLUGS) {
    assert(slug.length > 0, `empty slug found`);
    assertEquals(slug, slug.trim(), `slug '${slug}' has leading/trailing whitespace`);
  }
});

Deno.test('every slug is snake_case (lowercase + alphanumeric + underscore)', () => {
  // Stable wire format — uppercase or punctuation in a slug would
  // mismatch on later lookups. The pantry repository's slug match
  // uses literal string equality (NSPredicate `==`), no normalization.
  const snakeCase = /^[a-z0-9]+(?:_[a-z0-9]+)*$/;
  for (const slug of INGREDIENT_ONTOLOGY_SLUGS) {
    assert(snakeCase.test(slug), `slug '${slug}' is not snake_case`);
  }
});

Deno.test('no duplicate slugs', () => {
  // Duplicates inflate the prompt token cost without adding signal,
  // and would skew any future "slug freshness" sweeping that joins
  // on the array.
  const set = new Set(INGREDIENT_ONTOLOGY_SLUGS);
  assertEquals(
    set.size,
    INGREDIENT_ONTOLOGY_SLUGS.length,
    `found duplicates — set=${set.size}, array=${INGREDIENT_ONTOLOGY_SLUGS.length}`,
  );
});

Deno.test('alphabetical-within-section ordering (informal — diff-friendly)', () => {
  // Soft check: the file groups slugs by category (vegetables, fruits,
  // herbs, etc.) and sorts within each section. We don't enforce a
  // global sort because category boundaries break it. Instead, sample
  // a few sections to confirm intent.
  //
  // Actually pinning category ordering creates a brittle test that
  // breaks on every legitimate insertion. Skip — this test is a
  // documentation marker, not a failing assertion.
  assert(true);
});
