// Deterministic canonical_user_key hash for logs and ops_flagged_outputs.
// SHA-256 over the key, hex-encoded, truncated to 16 chars. Never log the
// raw canonical_user_key — this hash is the only identifier allowed in
// operational logs. See spec §11.

import { encodeHex } from '@std/encoding/hex';

export async function hashCanonicalKey(canonicalUserKey: string): Promise<string> {
  const bytes = new TextEncoder().encode(canonicalUserKey);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return encodeHex(new Uint8Array(digest)).slice(0, 16);
}
