# ADR 0034: CloudKit Web Services API token in the iOS bundle is exempt from north-star #2

- **Status**: Accepted
- **Date**: 2026-05-08
- **Owner-step**: Step 2 (CloudKit identity) / Step 9 (pre-public-launch hardening)
- **Related**: CLAUDE.md north-star #2; SCA-136 (server-side CloudKit identity verification); SCA-252 (this ADR's filing); `Stir/App/Info.plist` `CloudKitAPIToken`; `Config.xcconfig.example`; `Backend/supabase/functions/_shared/cloudkit_identity.ts`

## Context

CLAUDE.md north-star #2 reads "No provider API keys in the iOS bundle, ever." It's the bright-line rule that protects the Gemini key, OpenAI keys, RevenueCat private keys, etc. — keys whose disclosure compromises the whole product.

SCA-136 (server-side CloudKit identity verification) introduced a NEW key path: `Stir/App/Info.plist` reads `$(CLOUDKIT_API_TOKEN)` from `Config.xcconfig`, which iOS uses to mint short-lived `ckWebAuthToken`s via `CKFetchWebAuthTokenOperation(apiToken:)`. The minted user-bound token is what the bootstrap pipeline forwards to `verifyCloudKitIdentity`, which calls Apple's `users/caller` endpoint with both `ckAPIToken` (this one) and `ckWebAuthToken` (the user-bound one) as URL params.

The literal text of north-star #2 covers this token. Apple's design intent does not. From Apple's documentation:

> A CloudKit API token (also called a server-to-server key or container API token) identifies the requesting CloudKit container at the API layer. It does not grant access to user data on its own. To act on behalf of a specific user, a caller must additionally present a per-user `ckWebAuthToken` minted via Sign in with Apple or `CKFetchWebAuthTokenOperation`.
>
> — <https://developer.apple.com/documentation/cloudkitjs/setting_up_cloudkit_js>

A reviewer reading north-star #2 alone (CA1's review-5 finding W4) will flag the Info.plist entry as a violation. A reviewer who follows the Apple link will say "this token is by design public; that's why CloudKit JS exposes it in browser bundles." Both readings are reasonable. The rule has no exemption clause, which is why the conflict exists at all.

## Decision

CloudKit Web Services API tokens are explicitly exempt from CLAUDE.md north-star #2. The exemption is narrow and lists every member explicitly:

1. **CloudKit Web Services API token** (`Info.plist` `CloudKitAPIToken`, sourced from `Config.xcconfig` `CLOUDKIT_API_TOKEN`). Apple's design — the token identifies a container, not a caller. Cannot read or write user data on its own.
2. **Supabase anon key** (`Info.plist` `SupabaseAnonKey`, sourced from `Config.xcconfig` `SUPABASE_ANON_KEY`). RLS-enforced; per Supabase's threat model, the anon key is intended to ship in client code.

The amended rule (proposed for CLAUDE.md north-star #2):

> **No provider authentication credentials in the iOS bundle, ever.** Public container identifiers (CloudKit Web Services API token, Supabase anon key) are explicitly exempt — both are designed to ship in client code by their respective vendors and confer no authority on their own. Any new addition to this exemption list requires an ADR.

The CLAUDE.md amendment itself is **deferred** to a separate commit (Daniel was actively editing CLAUDE.md when this ADR was filed; the textual change is small and trivially mergeable when his edit lands). This ADR is the load-bearing record either way.

## Alternatives considered

- **Move the API token to a server-minted handshake.** Rejected because the token is the input to `CKFetchWebAuthTokenOperation`, which runs on the device — there is no server-side equivalent. Apple requires the device to call that operation directly to bind the resulting `ckWebAuthToken` to the local iCloud account.
- **Strip north-star #2's "ever" qualifier without an exemption list.** Rejected because the bright-line property of the rule is its primary value. A general "use judgment" clause would invite future drift; the explicit list keeps the surface visible.
- **Leave the rule as-is and document the violation in deferred-work.md.** Rejected because future readers reading the rule alone will keep re-flagging it as a /review finding, and "everyone knows the rule has an unwritten exemption" is exactly the failure mode the bright-line was meant to avoid.

## Consequences

### Positive

- The bright-line text of north-star #2 stays unambiguous on the protected class (Gemini, OpenAI, RevenueCat private keys, JWT signers, etc.). The exemption is a closed list — additions need an ADR.
- The rule no longer textually contradicts the codebase. /review-5 W4 closes.
- Future reviewers know precisely what's safe to ship: container-scoped or anon-scoped public identifiers vendored as client-side identifiers; everything else stays out of `Info.plist`.

### Negative

- Two-clause rules are slightly harder to remember than one-clause rules. The exemption list is a maintenance surface; if Apple ever changes the security posture of CloudKit Web Services tokens (unlikely), this ADR and the rule must be revisited.
- Anyone copying the Info.plist pattern for a new vendor without filing an ADR is now in violation by both the original rule (default-deny) AND the exemption-list discipline (additions need an ADR). Two-layered enforcement.

### Tradeoffs

- We're trading literal-text simplicity for accuracy. The cost is the maintenance of an explicit exemption list; the benefit is that the rule actually matches reality and stops generating false-positive /review findings.

## Notes

- Apple's CloudKit JS template ships the API token in browser-readable JavaScript. That is the public reference point for "this is intended to be a non-secret identifier."
- The user-bound `ckWebAuthToken` is the authority-bearing credential. It's short-lived (minted on demand), scoped to a specific user (the iCloud account active on the device at mint time), and cannot be re-used outside the bootstrap window. The CK identity verifier (`Backend/supabase/functions/_shared/cloudkit_identity.ts`) verifies the ckAPIToken + ckWebAuthToken pair against `api.apple-cloudkit.com/users/caller` per request — fail-closed on mismatch.
- Production activation of the SCA-136 verifier still requires `CLOUDKIT_API_TOKEN` to be set as a Supabase Edge Function secret matching the iOS-bundle value. Pre-activation, the verifier returns `verifier_unconfigured` and SCA-245's rollout-trust mode preserves the canonical-key resolution path; see `docs/deferred-work.md` for the activation procedure.
- This ADR's number (0034) follows 0033 (deletion-fulfillment-ordering, renumbered from 0031 in SCA-249 the same day).
