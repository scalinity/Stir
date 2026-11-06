import { assertEquals, assertNotEquals } from '@std/assert';
import { groceryCacheKey } from './grocery_cache_key.ts';
import type { GroceryGenerateRequest } from './validation.ts';

function request(): GroceryGenerateRequest {
  return {
    source_id: '00000000-0000-4000-8000-000000000001',
    source_type: 'recipe',
    ingredients_needed: [{ display_name: 'lemon', canonical_slug: 'lemon', amount_text: '1' }],
    pantry_snapshot: [],
    recipe_title: 'Lemon rice',
  };
}

Deno.test('grocery cache: identical immutable retries replay the existing diff', async () => {
  const body = request();
  const key = await groceryCacheKey(body);
  const missing = { missing_items: ['lemon'], already_have: [] };
  const cache = new Map([[key, missing]]);
  assertEquals(cache.get(await groceryCacheKey(structuredClone(body))), missing);
});

Deno.test('grocery cache: adding or removing a pantry item cannot replay a stale diff', async () => {
  const before = request();
  const after = {
    ...before,
    pantry_snapshot: [{ display_name: 'lemon', canonical_slug: 'lemon' }],
  };
  const beforeKey = await groceryCacheKey(before);
  const afterKey = await groceryCacheKey(after);
  assertNotEquals(beforeKey, afterKey);
  const cache = new Map([
    [beforeKey, { missing_items: ['lemon'], already_have: [] }],
    [afterKey, { missing_items: [], already_have: ['lemon'] }],
  ]);
  assertEquals(cache.get(await groceryCacheKey(after)), {
    missing_items: [],
    already_have: ['lemon'],
  });
  assertEquals(cache.get(await groceryCacheKey(before)), {
    missing_items: ['lemon'],
    already_have: [],
  });
});

Deno.test('grocery cache: recipe quantity, identity and source type are generation inputs', async () => {
  const body = request();
  const original = await groceryCacheKey(body);
  for (
    const changed of [
      { ...body, ingredients_needed: [{ ...body.ingredients_needed[0]!, amount_text: '2' }] },
      { ...body, ingredients_needed: [{ ...body.ingredients_needed[0]!, canonical_slug: 'lime' }] },
      { ...body, source_type: 'session' as const },
      { ...body, recipe_title: 'Lemon soup' },
    ]
  ) {
    assertNotEquals(await groceryCacheKey(changed), original);
  }
});

Deno.test('grocery cache: object key insertion order does not change retry identity', async () => {
  const body = request();
  const reordered = {
    ...body,
    ingredients_needed: [{ amount_text: '1', canonical_slug: 'lemon', display_name: 'lemon' }],
  };
  assertEquals(await groceryCacheKey(reordered), await groceryCacheKey(body));
});
