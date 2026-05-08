// RevenueCat webhook helpers.
//
// Covers:
//   - Constant-time Authorization header verification against
//     REVENUECAT_WEBHOOK_SECRET. RC's Auth model is a shared-secret header
//     (NOT HMAC-SHA256 of the body; see CLAUDE.md §Deferred + step-5
//     scope-confirmation notes).
//   - Zod schema for the RC webhook envelope. Required fields are minimal;
//     everything else is `.passthrough()` so new RC event shapes don't
//     break deploys.
//   - Product ID → tier mapping (hardcoded; spec §9 SKU strategy).
//   - Event type → `entitlement_snapshots` transition resolver. Each event
//     returns a discriminated Action that the handler applies verbatim.
//
// DESIGN: event → transition is PURE. No DB calls, no side effects. The
// handler does the IO. Makes unit testing trivial.

import { z } from 'zod';
import type { UserTier } from './auth.ts';
import type { BillingState } from './entitlements.ts';

// ---------------------------------------------------------------------------
// Authorization header verification
// ---------------------------------------------------------------------------

/**
 * Constant-time compare between the provided Authorization header value and
 * the configured shared secret. Length mismatch short-circuits to false
 * immediately (length-comparison is not a timing leak — the attacker already
 * controls the length they send).
 *
 * Node / Deno don't have a built-in `timingSafeEqual` on strings, and Deno
 * std's `crypto.timingSafeEqual` wants `Uint8Array`. Encode both sides and
 * use a bitwise XOR accumulator — identical to what `timingSafeEqual` does
 * internally.
 */
export function verifyAuthHeader(received: string | null, expected: string): boolean {
  if (!received) return false;
  if (received.length !== expected.length) return false;

  const receivedBytes = new TextEncoder().encode(received);
  const expectedBytes = new TextEncoder().encode(expected);
  // Length-equal already verified above, but TextEncoder can produce
  // different byte counts for the same character length (e.g. combining
  // marks). Defensive check before loop.
  if (receivedBytes.length !== expectedBytes.length) return false;

  let diff = 0;
  for (let i = 0; i < receivedBytes.length; i++) {
    // Non-null assertions are safe — Uint8Array indexing with i < length
    // always returns a byte. noUncheckedIndexedAccess in tsconfig types
    // the access as `number | undefined` so we coerce with `?? 0`.
    diff |= (receivedBytes[i] ?? 0) ^ (expectedBytes[i] ?? 0);
  }
  return diff === 0;
}

// ---------------------------------------------------------------------------
// Webhook envelope
// ---------------------------------------------------------------------------
//
// RC wraps everything in `{ event: { ... }, api_version: "1.0" }`. We capture
// only fields we rely on; everything else passes through unvalidated.
//
// Known event `type` values — intentionally a `z.string()` (not a strict
// enum) so a new RC event type doesn't fail the handler. The action
// resolver below decides whether we act on the type or ignore it.
//
// `app_user_id` is what RC calls the current subscriber identity; when
// SUBSCRIBER_ALIAS fires, `original_app_user_id` is the previous key the
// entitlement was attached to and `app_user_id` is the new winning key.
// For non-alias events they're the same.

/**
 * canonical_user_key shape: `ck:_<32-hex>` or `install:<uuid>`. The server
 * (stir_alias_forward, stir_process_webhook_event) derives behavior from
 * the prefix; an unrecognized format silently classifies as `install`
 * source_type with no audit trail. Validate at the boundary so an RC
 * dashboard "send test event" or a misconfigured customer import can't
 * pollute `app_users` with malformed rows.
 *
 * Letters: lowercase hex for CK records (per Apple spec §12 + April 2026
 * real-data validation); uuid dashes for install IDs (Keychain UUIDs
 * come from iOS `UUID()` which is v4 uppercase but RC normalizes; accept
 * both cases to be lenient).
 */
const CANONICAL_KEY_REGEX =
  /^(ck:_[a-f0-9]{32}|install:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$/;
const canonicalKey = z
  .string()
  .min(1)
  .max(256)
  .regex(CANONICAL_KEY_REGEX, "must be 'ck:_<32-hex>' or 'install:<uuid>'");

const RevenueCatEvent = z.object({
  id: z.string().min(1).max(256),
  type: z.string().min(1).max(64),
  event_timestamp_ms: z.number().int().nonnegative().optional(),
  app_user_id: canonicalKey,
  original_app_user_id: canonicalKey.optional(),
  aliases: z.array(z.string()).optional(),
  new_app_user_id: canonicalKey.optional(), // SUBSCRIBER_ALIAS
  transferred_from: z.array(canonicalKey).optional(), // TRANSFER
  transferred_to: z.array(canonicalKey).optional(), // TRANSFER
  product_id: z.string().min(1).max(256).optional(),
  period_type: z.string().min(1).max(64).optional(), // "NORMAL" | "INTRO" | "TRIAL" | "PROMOTIONAL"
  purchased_at_ms: z.number().int().nonnegative().optional(),
  expiration_at_ms: z.number().int().nonnegative().nullable().optional(),
  environment: z.enum(['SANDBOX', 'PRODUCTION']).optional(),
  store: z.string().min(1).max(64).optional(),
  is_family_share: z.boolean().optional(),
}).passthrough();

export const RevenueCatWebhookEnvelope = z.object({
  api_version: z.string().optional(),
  event: RevenueCatEvent,
}).passthrough();

// SA1-M1 (CWE-915 mass-assignment-adjacent): both schemas above are
// intentionally `.passthrough()` so RevenueCat schema additions don't
// break webhook deploys. The signature gate (`verifyAuthHeader`) means
// only RC can supply a payload, so unknown-key passthrough is bounded
// by RC's own contract surface.
//
// HOWEVER: any future consumer that persists the parsed event (e.g.,
// JSON.stringify into a JSONB audit-log column) MUST explicitly project
// the fields it cares about — never persist the full parsed payload.
// Persisting passthrough'd unknown fields would let a future RC schema
// addition silently land in our DB without review, and re-introduce
// the mass-assignment risk this comment is here to head off.

export type RevenueCatWebhookEnvelope = z.infer<typeof RevenueCatWebhookEnvelope>;
export type RevenueCatEvent = z.infer<typeof RevenueCatEvent>;

// ---------------------------------------------------------------------------
// Product ID → tier mapping
// ---------------------------------------------------------------------------
//
// Hardcoded per CLAUDE.md §StoreKit SKUs. Adding a new SKU requires updating
// both here AND the spec + CLAUDE.md tier entitlements table — do NOT
// silently add SKUs, they have to flow through cohort-economics math too.

export const PRODUCT_TIER_MAP: Readonly<Record<string, UserTier>> = Object.freeze({
  'stir.premium.monthly': 'premium',
  'stir.premium.annual.trial7': 'premium',
  'stir.pro.monthly': 'pro',
  'stir.pro.annual': 'pro',
});

export function productIdToTier(productId: string | undefined): UserTier | null {
  if (!productId) return null;
  return PRODUCT_TIER_MAP[productId] ?? null;
}

// ---------------------------------------------------------------------------
// Event → transition resolver (pure)
// ---------------------------------------------------------------------------
//
// The resolver consumes an RC event and produces one of:
//
//   { kind: 'upsert_entitlement', canonical_user_key, tier,
//     billing_state, is_trial, expires_at, preserve_tier_on_unknown_product }
//     Applied by the handler as an UPSERT on entitlement_snapshots keyed
//     on canonical_user_key.
//
//   { kind: 'alias', from, to }
//     Runs the identity merge helper: move entitlement_snapshots row
//     from `from` → `to` per CLAUDE.md aliasing rules (ck wins; discard
//     install row). app_users.merged_into linkage is handled by the
//     existing stir_alias_forward RPC in the handler.
//
//   { kind: 'transfer', from, to }
//     Reassign the entitlement_snapshots canonical_user_key from `from`
//     to `to`. TRANSFER is rare (Family Sharing boundary crossing even
//     though we turned Family Sharing off); logged at warn severity.
//
//   { kind: 'ignore', reason }
//     NON_RENEWING_PURCHASE, unknown event types, events on unknown
//     products. Handler logs and returns 200.
//
// `is_trial` is derived from `period_type`. `TRIAL` and `INTRO` both count
// as trial; `PROMOTIONAL` covers promo codes (treat as trial-ish but not
// here — the user had to have actively been in trial). Spec ties "intro
// offer" = 7-day free trial on `stir.premium.annual.trial7` only, which
// fires as `period_type === 'TRIAL'` in RC's current envelope.

export type EntitlementAction =
  | {
    kind: 'upsert_entitlement';
    canonical_user_key: string;
    tier: UserTier;
    billing_state: BillingState;
    is_trial: boolean;
    expires_at: string | null;
    /**
     * If the incoming product_id doesn't map to a known tier, the handler
     * logs a warning and short-circuits to 'ignore' — this flag exists so
     * the resolver stays pure. See `resolveEventAction`.
     */
    product_id: string;
  }
  | { kind: 'alias'; from: string; to: string }
  | { kind: 'transfer'; from: string; to: string }
  | { kind: 'ignore'; reason: string };

/** Convert RC epoch-millis to ISO 8601 string. */
function msToIso(ms: number | null | undefined): string | null {
  if (ms == null) return null;
  return new Date(ms).toISOString();
}

function isTrialPeriod(periodType: string | undefined): boolean {
  return periodType === 'TRIAL' || periodType === 'INTRO';
}

/**
 * Known RC event types. Ordering mirrors CLAUDE.md §"RC event → billing_state
 * transition" table for easy cross-checking.
 *
 * `as const` + `HandledEventType` union: any case added to the switch in
 * `resolveEventAction` that isn't listed here is a TS error (the switch's
 * `case` strings are checked against this union below). Prevents the drift
 * the step-5 review flagged where `HANDLED_EVENT_TYPES` was a loose Set<string>.
 */
export const HANDLED_EVENT_TYPE_LIST = [
  'INITIAL_PURCHASE',
  'RENEWAL',
  'CANCELLATION',
  'UNCANCELLATION',
  'BILLING_ISSUE',
  'EXPIRATION',
  'PRODUCT_CHANGE',
  'NON_RENEWING_PURCHASE', // explicitly ignored — spec has no NR SKUs
  'SUBSCRIBER_ALIAS',
  'TRANSFER',
] as const;

export type HandledEventType = typeof HANDLED_EVENT_TYPE_LIST[number];

export const HANDLED_EVENT_TYPES: ReadonlySet<string> = new Set<string>(HANDLED_EVENT_TYPE_LIST);

/**
 * Maximum accepted delivery age, in milliseconds. An event whose
 * `event_timestamp_ms` is older than this when the handler runs is
 * rejected as stale. Defense-in-depth against replay of captured
 * webhook deliveries (SA2/SA3 — the shared-secret auth model has no
 * body signing or built-in freshness check).
 *
 * 10 minutes is generous: RC's own retry schedule fires within seconds;
 * even a large regional outage rarely delays delivery beyond 5 min.
 * Captured-and-replayed events are far outside this window.
 */
export const MAX_EVENT_AGE_MS = 10 * 60 * 1000;

/**
 * Returns true when the event is fresh enough to process. Events
 * without `event_timestamp_ms` are accepted (RC test events sometimes
 * omit it; we don't want to reject tooling flows). Events more than
 * `MAX_EVENT_AGE_MS` in the past or with timestamps in the future (clock
 * skew or forgery) are rejected.
 */
export function isEventFresh(
  event: Pick<RevenueCatEvent, 'event_timestamp_ms'>,
  now: number = Date.now(),
): boolean {
  const ts = event.event_timestamp_ms;
  if (ts == null) return true; // RC test events omit; allow.
  const age = now - ts;
  // Past: age > window → stale. Future: age < 0 → clock skew or forgery;
  // allow up to 60s future tolerance for RC server-clock drift.
  return age >= -60_000 && age <= MAX_EVENT_AGE_MS;
}

export function resolveEventAction(event: RevenueCatEvent): EntitlementAction {
  const type = event.type;
  const canonicalKey = event.app_user_id;
  const tier = productIdToTier(event.product_id);
  const expiresAt = msToIso(event.expiration_at_ms ?? null);
  const isTrial = isTrialPeriod(event.period_type);

  switch (type) {
    case 'INITIAL_PURCHASE': {
      if (!tier) {
        return {
          kind: 'ignore',
          reason: `unknown product_id '${event.product_id ?? '<null>'}'`,
        };
      }
      const billingState: BillingState = isTrial ? 'trial' : 'active';
      return {
        kind: 'upsert_entitlement',
        canonical_user_key: canonicalKey,
        tier,
        billing_state: billingState,
        is_trial: isTrial,
        expires_at: expiresAt,
        product_id: event.product_id!,
      };
    }

    case 'RENEWAL': {
      if (!tier) {
        return {
          kind: 'ignore',
          reason: `unknown product_id '${event.product_id ?? '<null>'}'`,
        };
      }
      // Renewal always resolves billing_state to 'active' regardless of
      // whether the previous state was trial / active / cancelled_active.
      // `is_trial: false` — renewal charge means the trial converted.
      return {
        kind: 'upsert_entitlement',
        canonical_user_key: canonicalKey,
        tier,
        billing_state: 'active',
        is_trial: false,
        expires_at: expiresAt,
        product_id: event.product_id!,
      };
    }

    case 'CANCELLATION': {
      if (!tier) {
        return {
          kind: 'ignore',
          reason: `unknown product_id '${event.product_id ?? '<null>'}'`,
        };
      }
      // User cancelled; access continues until period_end. iOS UI shows
      // "Cancels <date>" banner with re-subscribe CTA.
      //
      // `is_trial: false` — the cancelled state is orthogonal to trial.
      // Even if the user cancels mid-trial (period_type='TRIAL' on the
      // event), the iOS UI treats cancelled_active + trial_preserved as a
      // self-contradiction: showing "free trial in progress" next to
      // "cancels on <date>" is confusing. Consolidate: once cancelled,
      // we're in the cancelled_active flow regardless of prior trial
      // status. Expiration or renewal (rare after cancel) will re-establish
      // the truth.
      return {
        kind: 'upsert_entitlement',
        canonical_user_key: canonicalKey,
        tier,
        billing_state: 'cancelled_active',
        is_trial: false,
        expires_at: expiresAt,
        product_id: event.product_id!,
      };
    }

    case 'UNCANCELLATION': {
      if (!tier) {
        return {
          kind: 'ignore',
          reason: `unknown product_id '${event.product_id ?? '<null>'}'`,
        };
      }
      // Un-cancelling implies the user is opting back in to a paid
      // subscription. By the time this event fires the original trial
      // has already been exited (a trial doesn't "un-cancel"; it converts
      // or expires). Hard-code is_trial=false rather than passing through.
      return {
        kind: 'upsert_entitlement',
        canonical_user_key: canonicalKey,
        tier,
        billing_state: 'active',
        is_trial: false,
        expires_at: expiresAt,
        product_id: event.product_id!,
      };
    }

    case 'BILLING_ISSUE': {
      if (!tier) {
        return {
          kind: 'ignore',
          reason: `unknown product_id '${event.product_id ?? '<null>'}'`,
        };
      }
      // Grace period: user keeps paid features while Apple retries. iOS
      // shows billing_retry_banner.
      return {
        kind: 'upsert_entitlement',
        canonical_user_key: canonicalKey,
        tier,
        billing_state: 'grace',
        is_trial: isTrial,
        expires_at: expiresAt,
        product_id: event.product_id!,
      };
    }

    case 'EXPIRATION': {
      // Expiration flips billing_state to 'expired'. effectiveTier() on the
      // server maps 'expired' → 'free' for feature gating regardless of
      // the tier column, so we can either store 'free' here or preserve
      // the prior tier for win-back targeting. Choosing to PRESERVE the
      // tier so the ops console can segment "expired Premium" vs "expired
      // Pro" for reactivation campaigns (step 8). The effective gating is
      // identical because effectiveTier() does the demotion.
      if (!tier) {
        // With no product_id, we don't know which tier they HAD. Store
        // 'free' as a conservative default — the row will no-op re-send
        // with 'expired' + 'free' if RC later replays.
        return {
          kind: 'upsert_entitlement',
          canonical_user_key: canonicalKey,
          tier: 'free',
          billing_state: 'expired',
          is_trial: false,
          expires_at: expiresAt,
          product_id: event.product_id ?? '',
        };
      }
      return {
        kind: 'upsert_entitlement',
        canonical_user_key: canonicalKey,
        tier,
        billing_state: 'expired',
        is_trial: false,
        expires_at: expiresAt,
        product_id: event.product_id!,
      };
    }

    case 'PRODUCT_CHANGE': {
      if (!tier) {
        return {
          kind: 'ignore',
          reason: `unknown product_id '${event.product_id ?? '<null>'}'`,
        };
      }
      // Tier flips to the new product's tier; billing_state stays 'active'.
      // Spec treats upgrade/downgrade identically — RC syncs entitlement
      // state via the subscription group.
      return {
        kind: 'upsert_entitlement',
        canonical_user_key: canonicalKey,
        tier,
        billing_state: 'active',
        is_trial: false,
        expires_at: expiresAt,
        product_id: event.product_id!,
      };
    }

    case 'NON_RENEWING_PURCHASE': {
      return {
        kind: 'ignore',
        reason: 'NON_RENEWING_PURCHASE not used by Stir (spec: subscriptions only)',
      };
    }

    case 'SUBSCRIBER_ALIAS': {
      // RC's alias event: `original_app_user_id` is the previous key,
      // `app_user_id` is the new winning key. We move entitlement_snapshots
      // from the old key to the new one. app_users.merged_into linkage
      // handled separately in the handler via the stir_alias_forward RPC.
      const from = event.original_app_user_id;
      const to = event.app_user_id;
      if (!from || !to || from === to) {
        return {
          kind: 'ignore',
          reason: `SUBSCRIBER_ALIAS missing or same-value original_app_user_id (from=${
            from ?? '<null>'
          }, to=${to})`,
        };
      }
      return { kind: 'alias', from, to };
    }

    case 'TRANSFER': {
      // TRANSFER: canonical_user_key changes due to subscription transfer
      // between Apple IDs. Family Sharing is off in spec but RC can still
      // fire this on boundary crossings. Rare.
      //
      // RC's payload shape for TRANSFER uses `transferred_from` and
      // `transferred_to` arrays. We treat the first element of each as the
      // canonical pair. No fallback to `event.app_user_id` for `to` —
      // TRANSFER semantics require BOTH arrays to be populated; an absent
      // `transferred_to` means the payload is malformed, and the right
      // behavior is to ignore (and log), not silently pick a different
      // canonical key that might re-apply the entitlement to the wrong
      // user.
      const from = event.transferred_from?.[0];
      const to = event.transferred_to?.[0];
      if (!from || !to || from === to) {
        return {
          kind: 'ignore',
          reason: `TRANSFER missing or same-value transferred_from/to (from=${
            from ?? '<null>'
          }, to=${to ?? '<null>'})`,
        };
      }
      return { kind: 'transfer', from, to };
    }

    default: {
      return { kind: 'ignore', reason: `unhandled event type '${type}'` };
    }
  }
}
