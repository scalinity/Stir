import './_helpers/env.ts';
import { assertEquals } from '@std/assert';
import { withOpsCors } from '../functions/_shared/ops_cors.ts';
const url = `${Deno.env.get('SUPABASE_URL')}/functions/v1/ops-admin`;
Deno.test('ops source CORS permits only configured SPA preflight and decorates auth errors', async () => {
  let handlerCalls = 0;
  const handler = () => {
    handlerCalls++;
    return Promise.resolve(new Response('{}', { status: 401 }));
  };
  const headers = {
    Origin: 'http://localhost:5173',
    'Access-Control-Request-Method': 'POST',
    'Access-Control-Request-Headers': 'authorization,content-type,x-request-id',
  };
  const preflight = await withOpsCors(new Request(url, { method: 'OPTIONS', headers }), handler);
  assertEquals(preflight.status, 204);
  assertEquals(preflight.headers.get('access-control-allow-origin'), headers.Origin);
  assertEquals(
    preflight.headers.get('access-control-allow-headers')?.includes('x-request-id'),
    true,
  );
  assertEquals(handlerCalls, 0);
  const denied = await withOpsCors(new Request(url, { method: 'POST', headers }), handler);
  assertEquals(denied.status, 401);
  assertEquals(denied.headers.get('access-control-allow-origin'), headers.Origin);
  const untrusted = await withOpsCors(
    new Request(url, {
      method: 'OPTIONS',
      headers: { ...headers, Origin: 'https://untrusted.invalid' },
    }),
    handler,
  );
  assertEquals(untrusted.status, 403);
  assertEquals(untrusted.headers.get('access-control-allow-origin'), null);
});
Deno.test('ops local gateway preflight permits requested headers and POST auth remains enforced', async () => {
  // Local Kong answers OPTIONS itself (200, wildcard) before the handler.
  const headers = {
    Origin: 'http://localhost:5173',
    'Access-Control-Request-Method': 'POST',
    'Access-Control-Request-Headers': 'authorization,content-type,x-request-id',
  };
  const preflight = await fetch(url, { method: 'OPTIONS', headers });
  await preflight.text();
  assertEquals(preflight.ok, true);
  assertEquals(
    preflight.headers.get('access-control-allow-headers')?.includes('x-request-id'),
    true,
  );
  const denied = await fetch(url, {
    method: 'POST',
    headers: { Origin: headers.Origin },
    body: '{}',
  });
  assertEquals(denied.status, 401);
  assertEquals(denied.headers.has('access-control-allow-origin'), true);
  await denied.text();
});
