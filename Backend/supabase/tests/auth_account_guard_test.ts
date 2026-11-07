import './_helpers/env.ts';
import { assertEquals } from '@std/assert';
import { requireActiveAccount } from '../functions/_shared/auth.ts';
import { quickBootstrap } from './_helpers/factory.ts';
import { serviceClient } from './_helpers/pg.ts';

Deno.test('account guard blocks JWT minted before ban and merged aliases', async () => {
  const client = serviceClient();
  const bs = await quickBootstrap();
  assertEquals(await requireActiveAccount(client, bs.canonical_user_key, 'guard-active'), null);
  await client.from('app_users').update({ status: 'banned' })
    .eq('canonical_user_key', bs.canonical_user_key).throwOnError();
  const denied = await requireActiveAccount(client, bs.canonical_user_key, 'guard-banned');
  assertEquals(denied?.status, 403);
  // Same pre-ban bearer token: pantry must reject even an invalid body before parsing it.
  const response = await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/pantry-parse`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${bs.session_jwt}`, 'content-type': 'application/json' },
    body: '{}',
  });
  assertEquals(response.status, 403);
  assertEquals((await response.json()).error, 'BILL-01');
  const alias = await quickBootstrap();
  await client.from('app_users').update({ status: 'merged', merged_into: bs.canonical_user_key })
    .eq('canonical_user_key', alias.canonical_user_key).throwOnError();
  const merged = await requireActiveAccount(client, alias.canonical_user_key, 'guard-merged');
  assertEquals(merged?.status, 401);
  assertEquals((await merged!.json()).reason, 'user_stale');
});
