import { assertEquals } from '@std/assert';
import { requestPostHogDeletion } from '../functions/_shared/posthog.ts';

const config = { apiKey: 'test-personal-key', projectId: '123', host: 'https://us.posthog.com' };
const queued = {
  deletion_errors: [],
  events_queued_for_deletion: true,
  recordings_queued_for_deletion: true,
};

Deno.test('PostHog deletion: absent credential retains manual action without a request', async () => {
  let called = false;
  const result = await requestPostHogDeletion('test-hash', {
    ...config,
    apiKey: '',
    fetchImpl: (() => {
      called = true;
      throw new Error('unexpected');
    }) as typeof fetch,
  });
  assertEquals(called, false);
  assertEquals(result.requires_manual_action, true);
  assertEquals(result.error, 'posthog_deletion_credentials_unset');
  assertEquals(result.submitted_at, undefined);
});

Deno.test('PostHog deletion: waits for authenticated deletion and preserves queued outcome', async () => {
  let release!: (response: Response) => void;
  let resolved = false;
  const request = requestPostHogDeletion('exact-user-hash', {
    ...config,
    fetchImpl: ((url: string | URL | Request, init?: RequestInit) => {
      assertEquals(String(url), 'https://us.posthog.com/api/projects/123/persons/bulk_delete/');
      assertEquals(init?.method, 'POST');
      assertEquals(new Headers(init?.headers).get('Authorization'), 'Bearer test-personal-key');
      assertEquals(init?.redirect, 'error');
      assertEquals(JSON.parse(String(init?.body)), {
        distinct_ids: ['exact-user-hash'],
        delete_events: true,
        delete_recordings: true,
      });
      return new Promise<Response>((resolve) => {
        release = resolve;
      });
    }) as typeof fetch,
  }).then((value) => {
    resolved = true;
    return value;
  });
  await Promise.resolve();
  assertEquals(resolved, false);
  release(Response.json(queued, { status: 202 }));
  const result = await request;
  assertEquals(result.requires_manual_action, true);
  assertEquals(typeof result.submitted_at, 'string');
  assertEquals('completed_at' in result, false);
});

Deno.test('PostHog deletion: HTTP and network failures cannot report submission', async () => {
  for (
    const fetchImpl of [
      (() =>
        Promise.resolve(new Response('private upstream detail', { status: 401 }))) as typeof fetch,
      (() =>
        Promise.reject(new DOMException('private timeout detail', 'TimeoutError'))) as typeof fetch,
    ]
  ) {
    const result = await requestPostHogDeletion('test-hash', { ...config, fetchImpl });
    assertEquals(result.requires_manual_action, true);
    assertEquals(result.submitted_at, undefined);
    assertEquals(JSON.stringify(result).includes('private'), false);
  }
});

Deno.test('PostHog deletion: partial queue response is retained for manual correction', async () => {
  for (
    const body of [{ ...queued, deletion_errors: ['failure'] }, {
      ...queued,
      events_queued_for_deletion: false,
    }, {}]
  ) {
    const result = await requestPostHogDeletion('test-hash', {
      ...config,
      fetchImpl: (() => Promise.resolve(Response.json(body, { status: 202 }))) as typeof fetch,
    });
    assertEquals(result.submitted_at, undefined);
    assertEquals(result.error, 'posthog_deletion_not_confirmed_queued');
  }
});

Deno.test('PostHog deletion: credential cannot be redirected through configuration', async () => {
  let called = false;
  const result = await requestPostHogDeletion('test-hash', {
    ...config,
    host: 'https://us.posthog.com.attacker.invalid',
    fetchImpl: (() => {
      called = true;
      throw new Error('unexpected');
    }) as typeof fetch,
  });
  assertEquals(called, false);
  assertEquals(result.error, 'posthog_deletion_configuration_invalid');
});
