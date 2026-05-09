# Stir — Architecture Decision Records

This directory is the historical record of material architectural choices. Claude Code reads it. Future-Daniel reads it. Together, they decide whether a past decision still holds.

## What belongs here

An ADR captures a decision that would cost time to re-derive. Write one when:

1. **A load-bearing choice is made** — stack selection, data-model boundary, security posture, SKU economics, auth model.
2. **A reasonable alternative was rejected** — document both the choice AND the runners-up, so a future revisit doesn't re-discover the same tradeoffs.
3. **A spec / CLAUDE.md rule gets added or retired** — the "why" lives here; the "what" stays in the spec.
4. **A deferred fix is accepted** — note the deferral, the trigger that reopens it, and who owns it.

An ADR does NOT belong here for:

- Day-to-day implementation choices (pick a library, name a function).
- Things fully captured by the code itself (struct shape, enum values).
- Bug fixes — those go in commits with reasoning.

**Rule of thumb:** if a future engineer reading the code alone would arrive at the same answer, no ADR needed. If they'd need to read meeting notes, conversation history, or re-run a cost model — write the ADR.

## File naming

```
NNNN-kebab-short-name.md
```

Where `NNNN` is a zero-padded sequential number. Never recycle numbers; never renumber existing ADRs. Superseded ADRs stay in place and link forward.

## Template

Copy `TEMPLATE.md`. Fill in every section. Keep prose tight — ADRs should be readable in under five minutes.

## Statuses

- **Proposed** — drafted but not yet committed to code.
- **Accepted** — in effect; code reflects it.
- **Deferred** — accepted in principle but work hasn't happened yet. Include a trigger and an owner-step.
- **Superseded by NNNN** — replaced; link forward. Do not delete.
- **Rejected** — considered and declined. Kept so the same idea doesn't come back unexamined.

## When Claude works on a decision

When user or context indicates a decision-worthy moment, Claude must:

1. Check this directory for a prior ADR on the topic.
2. If one exists and is Accepted/Deferred, follow it. Flag if user wants to revisit.
3. If the current work represents a new decision, create an ADR before (or alongside) the code change. Do NOT land a load-bearing choice without the ADR.
4. If code diverges from an Accepted ADR, either amend the ADR or revert the code. Silent divergence is banned.

## Index

| # | Title | Status | Relates to |
|---|-------|--------|------------|
| [0001](./0001-decisions-system.md) | Decisions system (this directory) | Accepted | CLAUDE.md §Decisions system |
| [0002](./0002-design-system-deferred.md) | Design system deferred; generic SwiftUI accepted through v1 beta | Deferred | FD1 review findings, step 9 beta |
| [0003](./0003-revenuecat-shared-secret-auth.md) | RevenueCat webhook uses shared-secret `Authorization` header, not HMAC | Accepted | webhook handler, SA2 review |
| [0004](./0004-supabase-entitlement-source-of-truth.md) | Supabase entitlement_snapshots is source of truth; RC is a refresh trigger only | Accepted | Billing model, CLAUDE.md §Billing |
| [0005](./0005-alias-forward-promote-entitlement.md) | stir_alias_forward promotes install→ck entitlement when ck has no row | Accepted | Migration 20260419000004 |
| [0006](./0006-gemini-live-oauth-service-account-mint.md) | Gemini Live mint uses OAuth service-account auth, not API key | **Rejected** (same day) — real blocker was paid-tier billing + legacy key format, not auth mode | CLAUDE.md §Gemini Live sharp-edges #16, #17, #18 · step-6 drift check |
| [0007](./0007-step-6-c3-before-c2.md) | Build Speech fallback (C.3) before Gemini Live (C.2) | Accepted | Phase C.2 (deferred) · Phase C.3 (next) · CLAUDE.md §Voice validation plan |
| [0008](./0008-voice-temporarily-free-for-testing.md) | Voice temporarily free for testing (step-6 dev build only) | **Superseded by 0015** (2026-04-23) | CLAUDE.md §North-star #6, `_shared/entitlements.ts`, ADR 0004, ADR 0015 |
| [0010](./0010-voice-max-output-tokens-300.md) | Raise `max_output_tokens` on voice turns from 150 → 400 (amended 2026-04-22 PM) | Accepted | CLAUDE.md §North-star #8, CLAUDE.md §Cost model, `_shared/live_mint.ts` |
| [0011](./0011-barge-in-deferred.md) | Native barge-in deferred; half-duplex gate + 0.5 s cooldown | Deferred | CLAUDE.md §Gemini Live sharp-edges, `RealtimeSession.startMicForwarding`, `LiveAudioPipeline.pendingPlaybackBuffers` |
| [0009](./0009-posthog-llm-observability.md) | PostHog LLM Observability as the primary AI-cost dashboard (dual-write with ai_request_log) | Accepted | Spec §15 "PostHog LLM Observability events", CLAUDE.md §Telemetry events, `_shared/ai_observability.ts`, `voice-turn-usage/index.ts` |
| [0012](./0012-step-6-v1-accepted-limitations.md) | Step 6 v1 accepted limitations — filler clip, pruning, session refresh, TTFA probe | Accepted (items A + D); items B + C Superseded by 0014 | CLAUDE.md §Voice validation plan, `RealtimeSession.swift`, ADR 0007, ADR 0010, ADR 0011 |
| [0013](./0013-ios-vs-backend-token-accounting.md) | iOS vs backend token accounting — two authorities, non-overlapping grains | Accepted | ADR 0009, `_shared/ai_observability.ts`, `voice-turn-usage/index.ts` |
| [0014](./0014-session-refresh-is-the-pruning-mechanism.md) | Session refresh IS the pruning mechanism on Gemini Live (supersedes ADR 0012 items B + C) | Accepted | CLAUDE.md §Gemini Live #1/#7, CLAUDE.md §Voice validation plan #4, Specs/Stir-Cook-Mode-Architecture.md §5, `_shared/validation.ts`, `_shared/live_mint.ts`, `realtime-session/index.ts`, `RealtimeSession.refreshSession()` |
| [0015](./0015-voice-cap-reduction-and-live-caching-finding.md) | Voice cap cut (Premium 20→13, Pro 40→27); lock "implicit caching does not fire on Live API" as permanent cost-model assumption | Accepted | CLAUDE.md §Tier entitlements, CLAUDE.md §Cost model, CLAUDE.md §Gemini Live sharp-edges #20, Spec §9, `_shared/entitlements.ts`, ADR 0008 (supersedes Free-tier cap portion) |
| [0016](./0016-design-tokens-in-shared-folder.md) | Design tokens live in `/Shared/` for App Group access across main + widget + share extension | Accepted | Spec §12 (file layout), EXTRACTED_TOKENS.md §9, ADR 0002, commit `66e9629` (step-7 Dynamic Type migration) |
| [0017](./0017-voice-session-owners-idor-binding.md) | `voice_session_owners` table binds session_id → canonical_user_key with supersede-on-mint lifecycle (closes SA2-W4 IDOR) | Accepted | Step-6 review P1-B, migration `20260423000003`, `realtime-session` handler, `voice-turn-usage` handler, `VoiceSessionReason` typed enum |
| [0018](./0018-refresh-outcome-transport-error-recovery.md) | `refreshSession` returns typed `RefreshOutcome`; `handleTransportError` dispatches on it instead of unconditionally demoting to `.error` | Accepted | Step-6 review P0-A, `RealtimeSession.refreshSession`, `.handleTransportError`, `.recordTurnAsTransportError`, ADR 0014, ADR 0015 |
| [0019](./0019-post-commit-refresh-failure-pins-c3-fallback.md) | Post-commit refresh failure pins C.3 fallback for the remainder of the Cook Mode entry | Accepted | Step-6 review P1-K, `RealtimeSession.onVoiceFallbackRequired`, `CookModeViewModel.pinFallbackForCookSession`, `CookModeRoot.buildVoiceDriver(forceFallback:)`, ADR 0017 |
| [0020](./0020-audio-interruption-observer-policy.md) | `AudioInterruptionObserver` tears down voice cleanly on system audio events; no in-place resume | Accepted | Step-6 review P0-D / CA2-Critical-1, `Stir/Integrations/Speech/AudioInterruptionObserver.swift`, both drivers' `handleAudioInterruption` |
| [0021](./0021-household-context-60s-ttl-cache.md) | Household context cached 60 s on the Live mint path; substitution path bypasses the cache | Accepted | Step-6 review P3-H, `RealtimeSession.buildHouseholdContext`, ADR 0014 |
| [0022](./0022-canonical-voice-context-pantry-filter.md) | Canonical pantry filter for voice context — `userConfirmed && !deletedAt && !displayName.isEmpty`, encoded in one place | Accepted | Step-6 review P2-I / CR1-W5, `HouseholdProfile.voiceContextSnapshot`, `VoiceContextSnapshot`, hard-rule validator invariant |
| [0023](./0023-admin-auth-via-supabase-auth.md) | Admin auth via Supabase Auth + `ops_admins` link table (separate JWT path from iOS session JWT) | Proposed | Spec §14, `_shared/admin_auth.ts`, `_shared/auth.ts`, migration `20260423000004_init_ops_admins.sql` |
| [0024](./0024-ops-spa-hosting.md) | Ops SPA runs from Vite dev server in step 8; deploys via Edge Function + Storage bucket in step 9 | Accepted (step 8) / Deferred (step 9 deploy) | Spec §14, `ops/` SPA, ADR 0023 |
| [0025](./0025-eval-harness-structure.md) | Eval harness structure — `Backend/evals/<feature>/` + shared infra + `STIR_RUN_AI_EVALS=1` gate; corpora deferred to step-9 prereq | Accepted (infra) / Deferred (corpus) | Spec §16, `Backend/evals/`, CLAUDE.md §Verification flows |
| [0026](./0026-reactivation-push-schedule.md) | Reactivation push via APNs daily 18:00 UTC, 14–21d inactivity, 30-day dedup — supersedes spec §8 Habit window row | Accepted | Spec §8 (amended), `_shared/apns.ts`, `stir_ops_reactivation_enqueue`, pg_cron `stir-reactivation-scan` |
| [0027](./0027-telemetry-canonical-property-schema.md) | Canonical property schema for PostHog and Sentry emits — pins `canonical_user_key_hash` as identity, `request_id` as cross-system join key, documents the `$ai_span_id` dual-id model, adopts spec↔code synchronization discipline | Accepted | Spec §15, CLAUDE.md §Telemetry events, ADR 0009, `docs/telemetry/canonical-properties.md`, `docs/telemetry/2026-04-24-audit.md` |
| [0028](./0028-pantry-management-surface.md) | Pantry management surface lives under Settings as a push sub-screen, not a fourth tab | Accepted | CLAUDE.md §Tier entitlements (`Remembered pantry items`), `SettingsRootView`, `ScanReviewView`, future `PantryListView` |
| [0029](./0029-pantry-auto-consume-on-cook-completion.md) | Auto-consume pantry items on cook completion — memory-state-aware rule, no confirmation prompt | Accepted | ADR 0028, `CookModeViewModel.performFinish`, `PantryItemRepository.consumeForRecipe`, SCA-21 through SCA-27, CLAUDE.md §AI pipeline map |
| [0030](./0030-preference-memory-on-device-digest.md) | Preference-memory loop computes the OutcomeFeedback digest on-device and ships it transient on the dinner-solve request body — closes the "I'll learn for next time" loop without breaking north-star #3 | Accepted | SCA-44, `PreferenceMemoryService`, `dinner-solve/index.ts`, `dinner_solve@2.0.0` migration, CLAUDE.md §Tier-entitlements ("Preference memory window"), spec §15 `dinner_solve_requested` |
| [0031](./0031-pgmq-dispatch-prod-url-hardcoded.md) | pgmq-dispatch prod URL hardcoded in migration; manual trigger restricted to literal-on-prod to prevent split-brain with the cron registration | Accepted | SCA-85, SCA-157, migrations `20260508000003_pgmq_dispatch_register_hardcoded_url.sql` + `20260508000004_pgmq_dispatch_cron_secret_header.sql`, CLAUDE.md §Deploy workflow |
| [0032](./0032-allergen-regenerator-botanical-allowlist.md) | Allergen-regenerator botanical-safe allowlist appends a coconut/butternut/nutmeg "safe for nut allergies" clause to the dinner-solve replacement userText; no `prompt_versions` template_blob bump because the change is in code, not template | Accepted | SCA-150, `_shared/hard_rules.ts` `ALLERGEN_BOTANICAL_SAFE_NOTES`, `dinner-solve/index.ts` `buildReplacementUserText`, `tests/dinner_solve_replacement_user_text_test.ts` |
| [0033](./0033-deletion-fulfillment-ordering.md) | Deletion fulfillment subsystem ordering — Postgres sweep last; success state anchored on audit_log (deletion_requests row is wiped by the cascade). Renumbered from 0031 in SCA-249 to resolve a number collision with 0031-pgmq-dispatch-prod-url-hardcoded; immutable-migration policy preserves the legacy "ADR 0031" string in the body of `20260508000008_drop_deletion_requests_completed_at.sql` (already-applied) — the link target post-rename is intentionally stale at that one site. | Accepted | SCA-88, SCA-249, `users-deletion-fulfill/index.ts`, `docs/runbooks/deletion-request-fulfillment.md` |
| [0034](./0034-cloudkit-api-token-in-ios-bundle.md) | CloudKit Web Services API token in the iOS bundle is exempt from CLAUDE.md north-star #2 ("No provider API keys in the iOS bundle, ever") — Apple's design ships container-scoped public tokens in client code; they grant no authority alone. Exemption list also includes Supabase anon key. CLAUDE.md textual amendment deferred to Daniel's active CLAUDE.md edit pass. | Accepted | SCA-136, SCA-252, `Stir/App/Info.plist` `CloudKitAPIToken`, `Config.xcconfig.example`, `_shared/cloudkit_identity.ts` |
| [0035](./0035-tier-downgrade-pantry-reconciliation.md) | Tier-downgrade pantry reconciliation — soft-archive `(used - cap)` oldest remembered rows to `.ephemeral` on Premium → Free transition; non-blocking banner; data preserved for re-upgrade restoration | Accepted | SCA-99, ADR 0028, ADR 0029, `EntitlementService.applyTierChange`, `PantryItemRepository.reconcileForTierChange`, CLAUDE.md §Tier entitlements |
