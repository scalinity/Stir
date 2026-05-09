import { assertEquals } from '@std/assert';
import { bodyWithVerifiedCloudKitOnly, verifyCloudKitIdentity } from './cloudkit_identity.ts';
import type { SessionBootstrapRequest } from './validation.ts';

const INSTALL_ID = '550e8400-e29b-41d4-a716-446655440000';
const CK_RECORD = '_1234567890abcdef1234567890abcdef';

function body(overrides: Partial<SessionBootstrapRequest> = {}): SessionBootstrapRequest {
  return {
    installation_id: INSTALL_ID,
    build: '1.0.0 (1)',
    os_version: '17.5',
    ...overrides,
  };
}

Deno.test('verifyCloudKitIdentity: not requested', async () => {
  const result = await verifyCloudKitIdentity(body(), { apiToken: 'api-token' });
  assertEquals(result.verified, false);
  assertEquals(result.reason, 'not_requested');
});

Deno.test('verifyCloudKitIdentity: missing web auth token fails closed', async () => {
  const result = await verifyCloudKitIdentity(
    body({ cloudkit_user_record_name: CK_RECORD }),
    { apiToken: 'api-token' },
  );
  assertEquals(result.verified, false);
  assertEquals(result.reason, 'missing_web_auth_token');
});

Deno.test('verifyCloudKitIdentity: missing API token fails closed without fetch', async () => {
  let fetchCalled = false;
  const result = await verifyCloudKitIdentity(
    body({ cloudkit_user_record_name: CK_RECORD, cloudkit_web_auth_token: 'web-auth-token' }),
    {
      apiToken: '',
      fetchImpl: (() => {
        fetchCalled = true;
        throw new Error('should not fetch');
      }) as typeof fetch,
    },
  );
  assertEquals(result.verified, false);
  assertEquals(result.reason, 'verifier_unconfigured');
  assertEquals(fetchCalled, false);
});

Deno.test('verifyCloudKitIdentity: matching users/caller record verifies', async () => {
  const seen = { url: '' };
  const result = await verifyCloudKitIdentity(
    body({ cloudkit_user_record_name: CK_RECORD, cloudkit_web_auth_token: 'web-auth-token' }),
    {
      apiToken: 'api-token',
      containerIdentifier: 'iCloud.com.scalinity.stir',
      environment: 'production',
      fetchImpl: ((url: URL) => {
        seen.url = url.toString();
        return Promise.resolve(Response.json({ users: [{ userRecordName: CK_RECORD }] }));
      }) as typeof fetch,
    },
  );
  assertEquals(result.verified, true);
  assertEquals(result.reason, 'verified');
  assertEquals(result.verifiedRecordName, CK_RECORD);
  assertEquals(
    seen.url.includes('/database/1/iCloud.com.scalinity.stir/production/public/users/caller'),
    true,
  );
  assertEquals(seen.url.includes('ckAPIToken=api-token'), true);
  assertEquals(seen.url.includes('ckWebAuthToken=web-auth-token'), true);
});

Deno.test('verifyCloudKitIdentity: record mismatch fails closed', async () => {
  const result = await verifyCloudKitIdentity(
    body({ cloudkit_user_record_name: CK_RECORD, cloudkit_web_auth_token: 'web-auth-token' }),
    {
      apiToken: 'api-token',
      containerIdentifier: 'iCloud.com.scalinity.stir',
      environment: 'production',
      fetchImpl: (() =>
        Promise.resolve(Response.json({
          users: [{ userRecordName: '_ffffffffffffffffffffffffffffffff' }],
        }))) as typeof fetch,
    },
  );
  assertEquals(result.verified, false);
  assertEquals(result.reason, 'record_mismatch');
});

Deno.test('verifyCloudKitIdentity: upstream rejection fails closed', async () => {
  const result = await verifyCloudKitIdentity(
    body({ cloudkit_user_record_name: CK_RECORD, cloudkit_web_auth_token: 'web-auth-token' }),
    {
      apiToken: 'api-token',
      containerIdentifier: 'iCloud.com.scalinity.stir',
      environment: 'production',
      fetchImpl: (() =>
        Promise.resolve(Response.json(
          { serverErrorCode: 'AUTHENTICATION_REQUIRED' },
          { status: 401 },
        ))) as typeof fetch,
    },
  );
  assertEquals(result.verified, false);
  assertEquals(result.reason, 'cloudkit_rejected');
  assertEquals(result.upstreamStatus, 401);
});

Deno.test('bodyWithVerifiedCloudKitOnly: strips unverified CK before resolution', () => {
  const original = body({
    cloudkit_user_record_name: CK_RECORD,
    cloudkit_web_auth_token: 'web-auth-token',
  });
  const stripped = bodyWithVerifiedCloudKitOnly(original, {
    verified: false,
    reason: 'record_mismatch',
  });
  assertEquals(stripped.cloudkit_user_record_name, undefined);
  assertEquals(stripped.cloudkit_web_auth_token, undefined);
});

// ---------------------------------------------------------------------------
// SCA-247 (C4 from /review-5): timeout-bounded fetch + cloudkit_timeout reason
// ---------------------------------------------------------------------------

Deno.test('verifyCloudKitIdentity: AbortSignal.timeout fires → cloudkit_timeout reason', async () => {
  const result = await verifyCloudKitIdentity(
    body({ cloudkit_user_record_name: CK_RECORD, cloudkit_web_auth_token: 'web-auth-token' }),
    {
      apiToken: 'api-token',
      // Stub fetch to throw the same DOMException shape AbortSignal.timeout
      // produces — name === 'TimeoutError' is the discriminator the
      // verifier uses to return cloudkit_timeout vs cloudkit_rejected.
      fetchImpl: ((_url: URL | string, init?: RequestInit) => {
        // Simulate the timeout that the *real* AbortSignal.timeout(3000)
        // would have produced if the upstream stalled past 3s. We don't
        // actually wait — we throw the exact DOMException the runtime
        // would throw. Verifies the discriminator without slowing the
        // test suite.
        const sig = init?.signal;
        if (sig?.aborted) {
          throw sig.reason as DOMException;
        }
        // Otherwise synthesize a fresh TimeoutError.
        throw new DOMException('signal timed out', 'TimeoutError');
      }) as typeof fetch,
    },
  );
  assertEquals(result.verified, false);
  assertEquals(result.reason, 'cloudkit_timeout');
  assertEquals(result.claimedRecordName, CK_RECORD);
});

Deno.test('verifyCloudKitIdentity: non-timeout fetch error → cloudkit_rejected (not cloudkit_timeout)', async () => {
  const result = await verifyCloudKitIdentity(
    body({ cloudkit_user_record_name: CK_RECORD, cloudkit_web_auth_token: 'web-auth-token' }),
    {
      apiToken: 'api-token',
      fetchImpl: (() => {
        throw new TypeError('network error');
      }) as typeof fetch,
    },
  );
  assertEquals(result.verified, false);
  assertEquals(result.reason, 'cloudkit_rejected');
  assertEquals(result.claimedRecordName, CK_RECORD);
});
