import type { SessionBootstrapRequest } from './validation.ts';

const DEFAULT_CLOUDKIT_CONTAINER = 'iCloud.com.scalinity.stir';
const DEFAULT_CLOUDKIT_ENVIRONMENT = 'production';
const CLOUDKIT_BASE_URL = 'https://api.apple-cloudkit.com';

// SCA-247 (C4 from /review-5): cap any single CloudKit upstream call at
// 3s. Bootstrap is the hottest path in the API surface, and Apple-side
// stalls were previously bounded only by the Edge Function 150s wall,
// which means an Apple incident would silently brick every iOS cold
// start. Mirrors the 8s cap users-deletion-fulfill (SCA-224) uses for
// Sentry/RevenueCat fetches; the bootstrap path picks a tighter cap
// because it's user-facing latency, not a background worker.
const CLOUDKIT_FETCH_TIMEOUT_MS = 3000;

export type CloudKitVerificationReason =
  | 'not_requested'
  | 'missing_web_auth_token'
  | 'verifier_unconfigured'
  | 'cloudkit_rejected'
  // SCA-247 (C4): Apple-side stall hit the 3s cap. Distinguished from
  // `cloudkit_rejected` so operators can tell "Apple is slow" from
  // "Apple said no" in incident triage.
  | 'cloudkit_timeout'
  | 'record_mismatch'
  | 'verified';

export interface CloudKitVerificationResult {
  verified: boolean;
  reason: CloudKitVerificationReason;
  claimedRecordName?: string;
  verifiedRecordName?: string;
  upstreamStatus?: number;
}

export interface CloudKitVerifierDeps {
  apiToken?: string;
  containerIdentifier?: string;
  environment?: 'development' | 'production';
  fetchImpl?: typeof fetch;
}

interface CloudKitCallerResponse {
  users?: Array<{ userRecordName?: string }>;
  userRecordName?: string;
}

export async function verifyCloudKitIdentity(
  body: SessionBootstrapRequest,
  deps: CloudKitVerifierDeps = {},
): Promise<CloudKitVerificationResult> {
  const claimedRecordName = body.cloudkit_user_record_name;
  if (claimedRecordName == null) {
    return { verified: false, reason: 'not_requested' };
  }
  if (body.cloudkit_web_auth_token == null) {
    return { verified: false, reason: 'missing_web_auth_token', claimedRecordName };
  }

  const apiToken = deps.apiToken ?? Deno.env.get('CLOUDKIT_API_TOKEN');
  if (apiToken == null || apiToken.trim() === '') {
    return { verified: false, reason: 'verifier_unconfigured', claimedRecordName };
  }

  const containerIdentifier = deps.containerIdentifier ??
    Deno.env.get('CLOUDKIT_CONTAINER_IDENTIFIER') ?? DEFAULT_CLOUDKIT_CONTAINER;
  const environment = deps.environment ?? cloudKitEnvironmentFromEnv();
  const url = new URL(
    `/database/1/${encodeURIComponent(containerIdentifier)}/${environment}/public/users/caller`,
    CLOUDKIT_BASE_URL,
  );
  url.searchParams.set('ckAPIToken', apiToken);
  url.searchParams.set('ckWebAuthToken', body.cloudkit_web_auth_token);

  const fetchImpl = deps.fetchImpl ?? fetch;
  let response: Response;
  try {
    // SCA-247 (C4): hard 3s cap on the upstream call. AbortSignal.timeout
    // surfaces as `DOMException` with `name === 'TimeoutError'`, which
    // we distinguish from generic network failures so the bootstrap log
    // and any future dashboards can split "Apple is slow" from "Apple
    // said no" in incident triage.
    response = await fetchImpl(url, {
      method: 'GET',
      signal: AbortSignal.timeout(CLOUDKIT_FETCH_TIMEOUT_MS),
    });
  } catch (err) {
    const isTimeout = err instanceof DOMException && err.name === 'TimeoutError';
    return {
      verified: false,
      reason: isTimeout ? 'cloudkit_timeout' : 'cloudkit_rejected',
      claimedRecordName,
    };
  }

  if (!response.ok) {
    return {
      verified: false,
      reason: 'cloudkit_rejected',
      claimedRecordName,
      upstreamStatus: response.status,
    };
  }

  let parsed: CloudKitCallerResponse;
  try {
    parsed = await response.json() as CloudKitCallerResponse;
  } catch {
    return {
      verified: false,
      reason: 'cloudkit_rejected',
      claimedRecordName,
      upstreamStatus: response.status,
    };
  }

  const verifiedRecordName = parsed.users?.[0]?.userRecordName ?? parsed.userRecordName;
  if (verifiedRecordName !== claimedRecordName) {
    return {
      verified: false,
      reason: 'record_mismatch',
      claimedRecordName,
      ...(verifiedRecordName === undefined ? {} : { verifiedRecordName }),
      upstreamStatus: response.status,
    };
  }

  return {
    verified: true,
    reason: 'verified',
    claimedRecordName,
    verifiedRecordName,
    upstreamStatus: response.status,
  };
}

export function bodyWithVerifiedCloudKitOnly(
  body: SessionBootstrapRequest,
  verification: CloudKitVerificationResult,
): SessionBootstrapRequest {
  if (body.cloudkit_user_record_name == null || verification.verified) return body;
  const {
    cloudkit_user_record_name: _recordName,
    cloudkit_web_auth_token: _token,
    ...installOnly
  } = body;
  return installOnly;
}

function cloudKitEnvironmentFromEnv(): 'development' | 'production' {
  const raw = Deno.env.get('CLOUDKIT_ENVIRONMENT');
  return raw === 'development' ? 'development' : 'production';
}
