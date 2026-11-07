// Real-provider regression for the substitution accept flow's two cost rows.
import { assert, assertEquals } from '@std/assert';
import { promoteToPremium, quickBootstrap, testIPHeaders } from './_helpers/factory.ts';
import { clearRateLimitBuckets, serviceClient } from './_helpers/pg.ts';

await clearRateLimitBuckets();

const FUNCTIONS_URL = `${Deno.env.get('SUPABASE_URL')}/functions/v1`;

Deno.test('recipe-step-rewrite: retains both cost rows after substitution with the same sub_event_id', async () => {
  const boot = await quickBootstrap();
  await promoteToPremium(boot.canonical_user_key);
  const subEventId = crypto.randomUUID();
  const headers = {
    'content-type': 'application/json',
    Authorization: `Bearer ${boot.session_jwt}`,
    ...testIPHeaders(),
  };
  const substitution = await fetch(`${FUNCTIONS_URL}/substitution`, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      sub_event_id: subEventId,
      cooking_session_id: crypto.randomUUID(),
      recipe_plan_id: crypto.randomUUID(),
      missing_ingredient: { display_name: 'heavy cream' },
      user_problem: 'out of heavy cream',
      household_context: {
        dietary_rules: [],
        available_equipment: ['stovetop', 'skillet'],
        pantry_snapshot: [{ display_name: 'whole milk' }, {
          display_name: 'butter',
        }],
      },
      recipe_context: {
        title: 'Tomato Cream Pasta',
        current_step_number: 2,
        total_steps: 5,
        remaining_ingredients: [{ display_name: 'pasta' }, {
          display_name: 'garlic',
        }],
      },
    }),
  });
  const swap = await substitution.json();
  assertEquals(substitution.status, 200, JSON.stringify(swap));
  assertEquals(swap.constraint_safe, true);
  assert(
    typeof swap.substitution_text === 'string' &&
      swap.substitution_text.length > 0,
  );

  const rewrite = await fetch(`${FUNCTIONS_URL}/recipe-step-rewrite`, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      sub_event_id: subEventId,
      step_instruction_text:
        'Stir 1/2 cup heavy cream into the tomato sauce and simmer for 2 minutes.',
      original_ingredient: 'heavy cream',
      substitute_ingredient: swap.substitution_text,
      ...(swap.amount_conversion ? { amount_conversion: swap.amount_conversion } : {}),
      recipe_title: 'Tomato Cream Pasta',
      dietary_rules: [],
      available_equipment: ['stovetop', 'skillet'],
    }),
  });
  const rewritten = await rewrite.json();
  assertEquals(rewrite.status, 200, JSON.stringify(rewritten));
  assertEquals(rewritten.sub_event_id, subEventId);
  assert(
    typeof rewritten.rewritten_text === 'string' &&
      rewritten.rewritten_text.length > 0,
  );

  // recordAIRequest runs under waitUntil; allow its writes to finish.
  const sb = serviceClient();
  let rows: { request_id: string; feature_key: string; cost_usd: number }[] = [];
  for (let attempt = 0; attempt < 50; attempt++) {
    const { data, error } = await sb.from('ai_request_log')
      .select('request_id, feature_key, cost_usd')
      .eq('canonical_user_key', boot.canonical_user_key)
      .in('request_id', [subEventId, `${subEventId}:rewrite`])
      .order('feature_key');
    if (error) throw error;
    rows = data ?? [];
    if (rows.length === 2) break;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assertEquals(
    rows.map(({ request_id, feature_key }) => ({ request_id, feature_key })),
    [
      {
        request_id: `${subEventId}:rewrite`,
        feature_key: 'recipe_step_rewrite',
      },
      { request_id: subEventId, feature_key: 'substitution' },
    ],
    'both substitution and recipe_step_rewrite must retain their own cost row',
  );
  for (const row of rows) {
    assert(row.cost_usd > 0, `${row.feature_key} must record provider cost`);
  }
});
