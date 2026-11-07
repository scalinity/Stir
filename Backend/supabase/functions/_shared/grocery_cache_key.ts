import type { GroceryGenerateRequest } from './validation.ts';

// A recipe keeps its identity when its ingredients or the pantry change.
// Bind cached diffs to the complete validated input so retries replay only
// the same generation, while a changed snapshot gets a fresh diff.
export async function groceryCacheKey(body: GroceryGenerateRequest): Promise<string> {
  const input = JSON.stringify({
    source_id: body.source_id,
    source_type: body.source_type,
    ingredients_needed: body.ingredients_needed.map((item) => ({
      display_name: item.display_name,
      canonical_slug: item.canonical_slug,
      amount_text: item.amount_text,
    })),
    pantry_snapshot: body.pantry_snapshot.map((item) => ({
      display_name: item.display_name,
      canonical_slug: item.canonical_slug,
    })),
    recipe_title: body.recipe_title,
  });
  const digest = new Uint8Array(
    await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input)),
  );
  return `grocery:${Array.from(digest, (byte) => byte.toString(16).padStart(2, '0')).join('')}`;
}
