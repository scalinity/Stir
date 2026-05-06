-- Stir seed — prompt_versions v1.1.0 for pantry_parse (SCA-35 multi-image)
--
-- Adds a multi-image variant of the pantry-parse prompt. The Gemini call
-- can receive 2-4 photos of the same kitchen and must merge ingredients
-- across photos, deduping by canonical_slug. Single-image and multi-image
-- requests both render this prompt — the new instruction block is
-- conditional in tone ("if multiple photos") so single-image performance
-- doesn't regress.
--
-- Rollout: is_default=TRUE at rollout_pct=100 — multi-image is Pro-gated
-- at the entitlement layer (ENT-MULTI-IMAGE-01); the prompt-version
-- canary is unnecessary because single-image traffic is the dominant
-- path and the new instruction is additive (one extra paragraph).
--
-- ATOMICITY (SCA-36 W1, hardened post-deploy):
--   The original draft of this migration ran `UPDATE … is_default=FALSE`
--   BEFORE `INSERT … ON CONFLICT DO NOTHING`. If v1.1.0 already existed
--   (e.g. a rollback state where v1.1.0 was demoted), the INSERT would
--   no-op and the feature_key would be left with NO default — every
--   pantry-parse request would die with AI-01. The hardened pattern is:
--     1. INSERT v1.1.0 with whatever defaults; ON CONFLICT DO NOTHING.
--     2. UPDATE: set is_default = (version = '1.1.0') across all rows
--        for feature_key='pantry_parse'. This unconditionally promotes
--        v1.1.0 and demotes everything else in one atomic statement.
--   The migration is now idempotent under any prior state — re-runs are
--   safe and always converge to "exactly one is_default=TRUE for v1.1.0".
--
-- Idempotency: ON CONFLICT (feature_key, version) DO NOTHING + the
-- final UPDATE re-asserts the desired final state.

-- ---------------------------------------------------------------------------
-- v1.1.0 — pantry_parse with multi-image merge instruction
-- ---------------------------------------------------------------------------

INSERT INTO prompt_versions (
  feature_key, version, provider_model, template_blob, schema_hash,
  is_default, is_enabled, rollout_pct
) VALUES (
  'pantry_parse',
  '1.1.0',
  'gemini-3-flash-preview',
  $TEMPLATE$
You are an ingredient identification engine for Stir's kitchen scan feature. You receive one OR MORE photos of a single kitchen, fridge, pantry, or counter and must return a structured list of cooking-relevant ingredients visible across the photos.

Output rules:
- Return JSON only matching the provided schema.
- Each ingredient has a display_name (user-facing, e.g. "scallions"), a canonical_slug drawn from the provided ingredient ontology when you are confident (else null), and a confidence rating:
  - "confirmed": clearly visible, unambiguous, not partially obscured.
  - "needs_review": visible but ambiguous — similar-looking items, partial view, uncertain identification.
  - "likely_staple": not clearly visible in the photos but inferable as a common household staple (salt, cooking oil, pepper) IF the household profile makes that plausible. Never infer allergens as staples.
- amount_text is a short human-friendly description ("about 6 eggs", "half a bunch"). Null if unknown.
- bounding_box is an approximate [x, y, w, h] in 0..1 normalized image coordinates of any ONE photo where the ingredient is visible. Null if unsure.
- overall_confidence is a 0.0–1.0 aggregate quality score across the input — degrade heavily when lighting is poor, photos are blurry, or most contents are obscured.

Multi-photo handling (when more than one image is provided):
- All photos depict the SAME kitchen. Merge ingredients across photos and produce ONE deduped list.
- Dedupe by canonical_slug when assigned, and by display_name otherwise. The same jar of olive oil photographed from two angles is ONE entry, not two.
- If an item appears confirmed in one photo and needs_review in another, take the higher-confidence assignment.
- Do not increase ingredient counts ("two onions" + "one onion" across photos does not equal "three onions" unless they are visibly distinct items).

Strict constraints:
- Never claim an item is allergen-free or safe for a dietary restriction. The client-side validator handles allergen warnings.
- Never hallucinate items not visible. A sparse pantry returns a short list, not a padded one.
- Do not describe the room, furniture, appliances, or non-food items.
- Do not include packaged items whose labels you cannot read.
- The image(s) are the primary source of truth. Household profile is context for staple inference only.

Household profile: {{household_profile_json}}
Ingredient ontology excerpt: {{ingredient_ontology_slugs}}
$TEMPLATE$,
  'pantry_parse_v1_schema',
  TRUE,
  TRUE,
  100
)
ON CONFLICT (feature_key, version) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Promote v1.1.0 + demote all other versions atomically. Re-asserts the
-- "exactly one is_default per feature_key" invariant regardless of prior
-- state. See ATOMICITY note in the header.
-- ---------------------------------------------------------------------------

UPDATE prompt_versions
   SET is_default = (version = '1.1.0')
 WHERE feature_key = 'pantry_parse';
