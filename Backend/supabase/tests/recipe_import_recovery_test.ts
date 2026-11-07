// Local HTTP + Postgres fixtures, no provider calls. Only unique test users/IDs.
import { assertEquals, assertExists } from '@std/assert';
import { quickBootstrap, testIPHeaders } from './_helpers/factory.ts';
import { serviceClient } from './_helpers/pg.ts';

const base = (Deno.env.get('SUPABASE_URL') ?? 'http://127.0.0.1:54321') +
  '/functions/v1/recipe-import';
const client = serviceClient();
async function call(jwt: string, id: string, post = false) {
  const response = await fetch(post ? base : `${base}?import_id=${id}`, {
    method: post ? 'POST' : 'GET',
    headers: {
      Authorization: `Bearer ${jwt}`,
      'content-type': 'application/json',
      ...testIPHeaders(),
    },
    ...(post
      ? {
        body: JSON.stringify({
          import_id: id,
          source_type: 'pasted_text',
          payload: { pasted_text: 'rice recipe '.repeat(1500) },
        }),
      }
      : {}),
  });
  return { status: response.status, body: await response.json() };
}
async function usage(key: string) {
  const { data, error } = await client.from('usage_counters').select(
    'used_count',
  )
    .eq('canonical_user_key', key).eq('feature_key', 'recipe_import').single();
  if (error) throw error;
  return data.used_count;
}

Deno.test('import HTTP concurrent/lost202 retries debit once; recovery, owner isolation, expiry never admit', async () => {
  const user = await quickBootstrap();
  const other = await quickBootstrap();
  const id = crypto.randomUUID();
  let jobID: string | undefined;
  try {
    const before = await usage(user.canonical_user_key);
    const responses = await Promise.all([
      call(user.session_jwt, id, true),
      call(user.session_jwt, id.toUpperCase(), true),
    ]);
    assertEquals(responses.map((r) => r.status), [202, 202]);
    assertEquals(
      responses[0]!.body.async_job_id,
      responses[1]!.body.async_job_id,
    );
    jobID = responses[0]!.body.async_job_id;
    assertExists(jobID);
    const lost202 = await call(user.session_jwt, id, true);
    assertEquals(lost202.body.async_job_id, jobID);
    const { data: jobs, error } = await client.from('notification_jobs').select(
      'id,payload_json',
    )
      .eq('canonical_user_key', user.canonical_user_key).eq(
        'kind',
        'recipe_import_async',
      ).eq(
        'payload_json->>import_id',
        id,
      );
    if (error) throw error;
    assertEquals(jobs!.length, 1);
    assertEquals(await usage(user.canonical_user_key), before + 1);
    assertEquals((await call(user.session_jwt, id)).body.status, 'queued');
    assertEquals((await call(other.session_jwt, id)).body.status, 'expired');

    // Simulate deterministic worker output at its real storage boundary.
    const completed = {
      import_id: id,
      status: 'completed',
      recipe: {
        title: 'Rice',
        ingredients: [{ display_name: 'rice' }],
        steps: [{ step_number: 1, instruction_text: 'Cook rice.' }],
        parse_quality: 'high',
      },
      retry_count: 0,
      prompt_version: '1.0.0',
      async_job_id: jobID,
    };
    const cached = await client.from('ai_response_cache').insert({
      canonical_user_key: user.canonical_user_key,
      request_id: id,
      feature_key: 'recipe_import',
      response_body: completed,
      status_code: 200,
    });
    if (cached.error) throw cached.error;
    const terminal = await client.from('notification_jobs').update({
      state: 'completed',
      processed_at: new Date().toISOString(),
    }).eq('id', jobID);
    if (terminal.error) throw terminal.error;
    assertEquals((await call(user.session_jwt, id)).body, completed);
    const { data: cleaned } = await client.from('notification_jobs').select(
      'payload_json',
    ).eq(
      'id',
      jobID,
    ).single();
    assertEquals('raw_content' in cleaned!.payload_json, false);
    assertEquals('original_url' in cleaned!.payload_json, false);

    const expired = await client.from('ai_response_cache').update({
      created_at: new Date(Date.now() - 601_000).toISOString(),
    })
      .eq('canonical_user_key', user.canonical_user_key).eq('request_id', id);
    if (expired.error) throw expired.error;
    assertEquals((await call(user.session_jwt, id)).body.status, 'expired');
    assertEquals(
      (await call(user.session_jwt, id, true)).body.status,
      'expired',
    );
    assertEquals(await usage(user.canonical_user_key), before + 1);
  } finally {
    if (jobID) await client.from('notification_jobs').delete().eq('id', jobID);
    await client.from('ai_response_cache').delete().eq(
      'canonical_user_key',
      user.canonical_user_key,
    ).eq('request_id', id);
  }
});

Deno.test('terminal failed/dead-letter import trigger removes raw input and source URL', async () => {
  const user = await quickBootstrap();
  const id = crypto.randomUUID();
  const { data, error } = await client.from('notification_jobs').insert({
    canonical_user_key: user.canonical_user_key,
    kind: 'recipe_import_async',
    state: 'processing',
    payload_json: {
      import_id: id,
      raw_content: 'private recipe fixture',
      original_url: 'https://example.com/private?token=fixture',
    },
  }).select('id').single();
  if (error) throw error;
  try {
    const result = await client.from('notification_jobs').update({
      state: 'failed',
    }).eq(
      'id',
      data.id,
    ).select('payload_json').single();
    if (result.error) throw result.error;
    assertEquals(result.data.payload_json, { import_id: id });
    assertEquals((await call(user.session_jwt, id)).body.status, 'failed');
  } finally {
    await client.from('notification_jobs').delete().eq('id', data.id);
  }
});

Deno.test('worker completion publishes cache and terminal cleanup in one transaction', async () => {
  const user = await quickBootstrap();
  const id = crypto.randomUUID();
  const { data: job, error } = await client.from('notification_jobs').insert({
    canonical_user_key: user.canonical_user_key,
    kind: 'recipe_import_async',
    state: 'processing',
    payload_json: { import_id: id, raw_content: 'Rice recipe fixture' },
  }).select('id').single();
  if (error) throw error;
  const completed = {
    import_id: id,
    status: 'completed',
    recipe: {
      title: 'Rice',
      ingredients: [{ display_name: 'rice' }],
      steps: [{ step_number: 1, instruction_text: 'Cook.' }],
      parse_quality: 'high',
    },
    retry_count: 0,
    prompt_version: '1',
    async_job_id: job.id,
  };
  try {
    const result = await client.rpc('stir_complete_recipe_import', {
      p_job_id: job.id,
      p_response: completed,
    });
    if (result.error) throw result.error;
    assertEquals(result.data, 'completed');
    assertEquals((await call(user.session_jwt, id)).body, completed);
    const { data: terminal } = await client.from('notification_jobs').select(
      'state,payload_json',
    ).eq('id', job.id).single();
    assertEquals(terminal!.state, 'completed');
    assertEquals(terminal!.payload_json, { import_id: id });
    const replay = await client.rpc('stir_complete_recipe_import', {
      p_job_id: job.id,
      p_response: completed,
    });
    assertEquals(replay.data, 'completed');
  } finally {
    await client.from('notification_jobs').delete().eq('id', job.id);
    await client.from('ai_response_cache').delete().eq(
      'canonical_user_key',
      user.canonical_user_key,
    ).eq('request_id', id);
  }
});

Deno.test('import HTTP rejects canonical private IPv6 before admission or quota debit', async () => {
  const user = await quickBootstrap();
  const before = await usage(user.canonical_user_key);
  for (
    const url of [
      'http://[::1]/',
      'http://[::ffff:7f00:1]/',
      'http://[fd00::1]/',
    ]
  ) {
    const response = await fetch(base, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${user.session_jwt}`,
        'content-type': 'application/json',
        ...testIPHeaders(),
      },
      body: JSON.stringify({
        import_id: crypto.randomUUID(),
        source_type: 'url',
        payload: { url },
      }),
    });
    assertEquals(response.status, 502);
    assertEquals((await response.json()).error, 'IMPORT-01');
  }
  assertEquals(await usage(user.canonical_user_key), before);
});

Deno.test('import GET and POST replay reject pre-ban and merged JWTs before cache or queued metadata', async () => {
  const user = await quickBootstrap();
  const target = await quickBootstrap();
  const id = crypto.randomUUID();
  const queuedID = crypto.randomUUID();
  let jobID: string | undefined;
  const before = await usage(user.canonical_user_key);
  try {
    const cache = await client.from('ai_response_cache').insert({
      canonical_user_key: user.canonical_user_key,
      request_id: id,
      feature_key: 'recipe_import',
      status_code: 200,
      response_body: { import_id: id, status: 'completed', recipe: { title: 'Private fixture' } },
    });
    if (cache.error) throw cache.error;
    const queued = await client.from('notification_jobs').insert({
      canonical_user_key: user.canonical_user_key,
      kind: 'recipe_import_async',
      state: 'pending',
      scheduled_at: new Date(Date.now() + 86_400_000).toISOString(),
      payload_json: {
        import_id: queuedID,
        source_type: 'pasted_text',
        raw_content: 'Private pending fixture',
      },
    }).select('id').single();
    if (queued.error) throw queued.error;
    jobID = queued.data.id;
    assertEquals((await call(user.session_jwt, id)).body.status, 'completed');
    assertEquals((await call(user.session_jwt, queuedID)).body.status, 'queued');
    for (const state of ['banned', 'merged']) {
      const updated = await client.from('app_users').update({
        status: state,
        merged_into: state === 'merged' ? target.canonical_user_key : null,
      }).eq('canonical_user_key', user.canonical_user_key);
      if (updated.error) throw updated.error;
      for (const importID of [id, queuedID]) {
        for (const post of [false, true]) {
          const rejected = await call(user.session_jwt, importID, post);
          assertEquals(rejected.status, state === 'banned' ? 403 : 401);
          assertEquals(rejected.body.error, state === 'banned' ? 'BILL-01' : 'AUTH-01');
        }
      }
    }
    assertEquals(await usage(user.canonical_user_key), before);
  } finally {
    await client.from('app_users').update({ status: 'active', merged_into: null }).eq(
      'canonical_user_key',
      user.canonical_user_key,
    );
    if (jobID) await client.from('notification_jobs').delete().eq('id', jobID);
    await client.from('ai_response_cache').delete().eq(
      'canonical_user_key',
      user.canonical_user_key,
    ).eq('request_id', id);
  }
});
