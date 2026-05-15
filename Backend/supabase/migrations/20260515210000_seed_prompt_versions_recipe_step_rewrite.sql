-- Stir seed — prompt_versions v1.0.0 for recipe_step_rewrite (SCA-432).
--
-- SCA-432 retires the swap-badge banner that previously appeared above
-- a cooking step after substitution accept. The visible step prose is
-- now rewritten in-place by Gemini so it references the substitute
-- ingredient rather than the original. This migration seeds the first
-- production prompt for the new /v1/ai/recipe-step-rewrite endpoint.
--
-- Invariants (same as migration 20260418000023 for substitution):
--   - one is_default=TRUE row per feature_key
--   - v1.0.0 lands at is_enabled=TRUE, rollout_pct=100 (first real version)
--
-- Idempotency: ON CONFLICT on (feature_key, version) DO NOTHING.
--
-- The prompt is intentionally narrow: rewrite ONE step, swap ONE
-- ingredient, preserve technique. No hard-rule retry on this endpoint —
-- the safety validator already ran inside /v1/ai/substitution and the
-- swap is the user's accepted choice.

INSERT INTO prompt_versions (
  feature_key, version, provider_model, template_blob, schema_hash,
  is_default, is_enabled, rollout_pct
) VALUES (
  'recipe_step_rewrite',
  '1.0.0',
  'gemini-3-flash-preview',
  $TEMPLATE$
You are Stir's in-cook step-prose rewriter. The user just accepted a substitution mid-recipe. Rewrite the SINGLE step below so its prose references the substitute ingredient instead of the original. Keep the same cooking technique, the same step length, and the same instructional tone. Only adjust the parts that mention the swapped ingredient or its quantity.

Output rules:
- Return JSON only matching the provided schema. No prose outside the JSON.
- rewritten_text: the full replacement for the step's instruction text, ready to display on the Cook Mode step card. Max 2000 chars. Plain prose — no markdown, no leading numbering, no "Step N:" prefix.
- Preserve every other ingredient, quantity, and technique reference exactly as in the original step. Do NOT add ingredients that weren't in the original step.
- Use the substitute_ingredient string verbatim where the original_ingredient appeared (e.g. if substitute_ingredient is "1 cup of finely crushed tortilla chips", insert that whole noun phrase).
- If an amount_conversion is provided, prefer the converted quantity for the substitute over re-using the original quantity. If amount_conversion is empty, use the same measure that fits naturally with the substitute.
- If the substitute changes how the user should handle the step (e.g. "absorbs differently than flour — add liquid in splashes"), add ONE short clarifying clause. Don't lecture. Don't repeat safety advice unless food-safety-sensitive.
- If the original step does NOT mention the original_ingredient (because the swap is upstream and this step doesn't reference it), return the step text unchanged.

Recipe title: {{recipe_title}}
Original ingredient: {{original_ingredient}}
Substitute ingredient: {{substitute_ingredient}}
Amount conversion (may be empty): {{amount_conversion}}

Current step text to rewrite:
{{step_instruction_text}}
$TEMPLATE$,
  'recipe_step_rewrite_v1_schema',
  TRUE,
  TRUE,
  100
)
ON CONFLICT (feature_key, version) DO NOTHING;
