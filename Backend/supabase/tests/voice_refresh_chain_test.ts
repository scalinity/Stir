// Local database tests: no upstream model calls, fresh identities per case.
import { assert, assertEquals } from '@std/assert';
import { quickBootstrap } from './_helpers/factory.ts';
import { serviceClient } from './_helpers/pg.ts';

const client = serviceClient();
async function claim(key: string, cook: string, refresh: boolean) {
  const session = crypto.randomUUID();
  const { data, error } = await client.rpc('stir_voice_session_claim', {
    p_session_id: session,
    p_canonical_user_key: key,
    p_cooking_session_id: cook,
    p_is_refresh: refresh,
  });
  if (error) throw error;
  return { session, accepted: data as boolean };
}
async function ready(key: string, session: string) {
  const { data, error } = await client.rpc('stir_voice_session_ready', {
    p_session_id: session,
    p_canonical_user_key: key,
  });
  if (error) throw error;
  assertEquals(data, true);
}
async function chargedRoot(key: string, cook: string) {
  // Production debits usage_counters before admitting a charged root.
  const root = await claim(key, cook, false);
  assert(root.accepted);
  await ready(key, root.session);
  return root.session;
}
Deno.test('voice continuation rejects unproved, wrong-owner and wrong-cook refreshes', async () => {
  const a = await quickBootstrap();
  const b = await quickBootstrap();
  const cook = crypto.randomUUID();
  assertEquals((await claim(a.canonical_user_key, cook, true)).accepted, false);
  await chargedRoot(a.canonical_user_key, cook);
  assertEquals((await claim(b.canonical_user_key, cook, true)).accepted, false);
  assertEquals((await claim(a.canonical_user_key, crypto.randomUUID(), true)).accepted, false);
  assertEquals((await claim(a.canonical_user_key, cook, true)).accepted, true);
});
Deno.test('voice continuation atomically admits one pending successor and abort restores predecessor', async () => {
  const { canonical_user_key: key } = await quickBootstrap();
  const cook = crypto.randomUUID();
  const root = await chargedRoot(key, cook);
  const attempts = await Promise.all([claim(key, cook, true), claim(key, cook, true)]);
  assertEquals(attempts.filter((a) => a.accepted).length, 1);
  const winner = attempts.find((a) => a.accepted)!;
  const { error } = await client.rpc('stir_voice_session_abort', {
    p_session_id: winner.session,
    p_canonical_user_key: key,
  });
  if (error) throw error;
  const { data: restored } = await client.from('voice_session_owners').select(
    'session_id, closed_at',
  )
    .eq('session_id', root).single();
  assertEquals(restored?.closed_at, null);
  const retry = await claim(key, cook, true);
  assert(retry.accepted);
  await ready(key, retry.session);
  const { data: rows } = await client.from('voice_session_owners')
    .select('session_id, root_started_at, quota_charged_at').in('session_id', [
      root,
      retry.session,
    ]);
  assertEquals(rows?.length, 2);
  assertEquals(rows?.[0]?.root_started_at, rows?.[1]?.root_started_at);
  assertEquals(rows?.[0]?.quota_charged_at, rows?.[1]?.quota_charged_at);
});
Deno.test('voice continuation refuses aged root and uncharged legacy session', async () => {
  const { canonical_user_key: key } = await quickBootstrap();
  const cook = crypto.randomUUID();
  const root = await chargedRoot(key, cook);
  const { error } = await client.from('voice_session_owners')
    .update({ root_started_at: new Date(Date.now() - 121 * 60_000).toISOString() }).eq(
      'session_id',
      root,
    );
  if (error) throw error;
  assertEquals((await claim(key, cook, true)).accepted, false);
  await client.from('voice_session_owners').update({
    root_started_at: new Date().toISOString(),
    quota_charged_at: null,
  }).eq('session_id', root);
  assertEquals((await claim(key, cook, true)).accepted, false);
});
