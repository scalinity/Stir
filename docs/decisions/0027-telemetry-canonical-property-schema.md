# ADR 0027: Canonical property schema for PostHog and Sentry emits

- **Status**: Accepted
- **Date**: 2026-04-24
- **Owner-step**: standing (applies to every new emit + every Sentry capture from this point forward)
- **Related**: ADR 0009 (PostHog LLM Observability dual-write) · Spec §15 (Telemetry events + LLM Observability) · CLAUDE.md §Telemetry events · `docs/telemetry/canonical-properties.md` (reference) · `docs/telemetry/2026-04-24-audit.md` (Phase A audit) · `_shared/posthog.ts` · `_shared/ai_observability.ts` · `_shared/logger.ts` (`requestIdFrom`) · Step-8 telemetry wiring bundle

## Context

The 2026-04-24 telemetry audit (`docs/telemetry/2026-04-24-audit.md`) found
three structural gaps that make a future unified observability dashboard
impossible:

1. **Property-name drift.** The same 16-char SHA-256 hash of
   `canonical_user_key` appears under five different names across
   surfaces (`canonical_user_key_hash`, `canonical_key_hash`,
   `user_hash`, `keyHash`, `user.userId`). Cross-surface dashboard
   joins cannot key on a single name.
2. **Cross-system join has no universal key.** Backend function logs
   universally include `request_id`; backend PostHog `$ai_generation`
   uses `$ai_span_id` = iOS-body feature-specific id (`solve_request_id`,
   `import_id`, etc.), not the Edge Function's `x-request-id`; iOS
   Sentry captures carry zero `request_id`; backend SQL Sentry
   dispatch (cost anomalies) carries zero `request_id`.
3. **Spec / alerts / runbooks drift from emit code.** `docs/sentry/alerts.md`
   already contains two alert rules that query properties not emitted
   by production code (`cook_turn_resolved.preamble_present_rate`;
   `sync_state_changed.state`). Spec §9 proposes 8 `ops_admin.*`
   events with zero implementations. Nothing forces the spec↔code
   sync; drift is permanent once it lands.

ADR 0009 established PostHog LLM Observability as the primary AI cost
dashboard with a `recordAIRequest` helper enforcing the `$ai_generation`
property contract. That contract is narrow (AI calls only). The step-8
ops-admin surface, the step-8 cost-anomaly Sentry path, and every
non-AI PostHog emit are unconstrained. We need the same property-contract
discipline at a wider scope.

## Decision

**Adopt a canonical property schema covering every PostHog event and
every Sentry capture, documented in `docs/telemetry/canonical-properties.md`
as the living reference.**

1. **Canonical user-identity name:** `canonical_user_key_hash` (16-char
   SHA-256 prefix). Every property / tag referring to the hashed
   canonical key uses this name. Deprecated names (`canonical_key_hash`,
   `user_hash`) get a migration table; no in-place rename in this
   bundle — names migrate at the next organic touch of the owning
   call site.
2. **Canonical cross-system join key:** `request_id` (TEXT — UUID OR
   `voice:<session_id>:<turn_index>` form, both accepted by
   `requestIdFrom` at `_shared/logger.ts:80-84`). Every Sentry capture
   must include it when the causing request context is available; every
   PostHog event on a request-scoped surface should include it.
3. **Accept the intentional dual-id model** on PostHog AI events:
   `$ai_span_id` = iOS-body feature-specific id (stable across
   retries, the thing dashboards aggregate by feature), `request_id`
   = Edge Function `x-request-id` (joins PostHog to Supabase function
   logs). They serve different joins; the schema documents both
   explicitly rather than collapsing them.
4. **Event-name convention:** `<surface>.<noun>.<verb_or_state>`
   past-tense, dotted, for **new** event surfaces (`ops_admin.*`,
   future `billing_webhook.*`, etc.). Existing spec §15 events are
   grandfathered in their flat `<subject>_<past_verb>` form
   (`scan_submitted`, `cook_turn_resolved`, ...); they are NOT
   renamed — CLAUDE.md's allow-list and the snapshot test are the
   guardrails for those.
5. **PII rules, non-negotiable:** never emit `actor_email`, raw
   `canonical_user_key`, `$ai_input`, `$ai_output_choices`, or any
   field derived from user free-text (recipe titles, transcripts, AI
   response body). Structured metadata only (tokens, costs, latencies,
   durations, enum states).
6. **Synchronization discipline:** any new alert rule in
   `docs/sentry/alerts.md`, any new event in spec §15 or CLAUDE.md
   §Telemetry events, or any new property referenced by
   `docs/posthog/dashboards.json` MUST link to the emit source in the
   same commit. If the emit doesn't exist yet, the rule/event lands
   marked "UNIMPLEMENTED (emit source: TODO)" so grep finds the gap;
   it does NOT land silent.
7. **Enforcement is review-time** at adoption. Type-level enforcement
   (snapshot tests mapping every event to its required properties; a
   Zod-equivalent for PostHog property dicts) is deferred — CLAUDE.md
   §Deferred entry. Reviewer asks "does this emit carry
   `canonical_user_key_hash` + `request_id` where applicable, and does
   every new schema entry correspond to a live emit?"

## Alternatives considered

- **Rename every deprecated property name at its current call site in
  this bundle.** Rejected as scope creep: iOS `canonical_key_hash` →
  `canonical_user_key_hash` is an iOS-source edit (brief puts iOS
  source out of scope), backend `user_hash` rename touches a SQL
  function + the Sentry event body + any dashboard that queries it.
  These are real migrations; they each deserve standalone commits
  with dashboard-validation afterward. Not this bundle.
- **Collapse `$ai_span_id` and `request_id` into a single id by
  having the Edge Function use iOS's body id as its own
  `x-request-id`.** Rejected: the iOS body id identifies the LOGICAL
  call (stable across retries, cache hits); the Edge Function's
  `x-request-id` identifies the PHYSICAL HTTP request (one per hit).
  They serve different joins. Collapsing loses retry granularity in
  function logs and makes cache-hit rows indistinguishable from
  fresh ones.
- **Define the schema in spec §15 directly instead of an ADR + a
  reference doc.** Rejected: ADR captures the *decision* and its
  rationale / alternatives; the reference doc captures the *living
  rules* and gets updated as new canonical properties emerge.
  Putting both in spec §15 would mix decision-history with
  reference-material, which is exactly the anti-pattern ADRs were
  introduced to avoid.
- **Retrofit `recordAIRequest`-style typed helpers for every
  non-AI PostHog surface (typed builder per event, compile-time
  property enforcement).** Rejected in this bundle: large refactor
  across ~40 iOS call sites, would ship without the Phase C ops-admin
  wiring that blocks dashboard work today. Filed as §Deferred; revisit
  when the schema has stabilized and type-level enforcement delivers
  clear value vs review-time discipline.
- **Drop the "synchronization discipline" rule and rely on eventual
  consistency.** Rejected: the audit found two alerts referencing
  non-existent properties; without a rule, more will land. Review-time
  discipline costs minutes; silent alert failure costs real ops
  time during an incident.

## Consequences

### Positive

- **Dashboard joins become possible.** Any PostHog event carrying
  `canonical_user_key_hash` can join Sentry captures carrying the
  same name on user-scoped dashboards; any Sentry + PostHog event
  with `request_id` can co-correlate a single causing request.
- **New emit surfaces inherit the contract by default.** Phase C
  (ops-admin 8 events) has a schema to conform to before the first
  emit lands. Future surfaces (webhook-processed, session-bootstrap
  completed, etc. — when/if descope opens up) know the baseline.
- **Spec ↔ code drift gets caught at review.** The
  synchronization-discipline rule converts two of today's failure
  modes (alerts referencing non-existent properties, spec listing
  events that never emit) into a structured review item.
- **Backward-compat is explicit.** The deprecation table documents
  what's in the air today; nothing silent ships; renames happen on a
  known cadence (organic-touch triggers).

### Negative

- **Deprecated names stay on the wire indefinitely.** Until a call
  site is touched for other reasons, `canonical_key_hash` (iOS
  Sentry context) and `user_hash` (backend SQL Sentry tag) keep
  flowing to the two systems. Dashboards relying on canonical names
  for joins must include both the canonical AND deprecated forms
  until migration completes, OR accept reduced join fidelity on
  rows written before the rename.

  **Update 2026-05-07 (SCA-59):** the backend `tags.user_hash` →
  `tags.canonical_user_key_hash` cutover (migration `20260424000007`,
  deployed 2026-04-24) reached its 14-day Sentry index settle window
  on 2026-05-08. The cost-anomaly dispatcher now emits exclusively
  the canonical tag; old events under `tags.user_hash` will age out
  of Sentry's retention window naturally. **Sentry workspace owners**:
  drop the dual-query branch from any dashboard / saved search / alert
  rule referencing `tags.user_hash`; see `docs/telemetry/canonical-properties.md`
  §Sentry tag deprecation for the rotation timestamps. iOS-side
  `canonical_key_hash` remains an open deprecation with no retirement
  date scheduled.
- **Review-time enforcement is fallible.** A reviewer who forgets to
  ask "does this new event have `request_id`?" lets drift through.
  Mitigation: add a one-line checklist to `docs/telemetry/canonical-properties.md`
  that reviewers can paste into PR comments.
- **No runtime guard against missing properties.** An emit that
  forgets a mandatory property succeeds silently (PostHog accepts
  partial property dicts; Sentry accepts empty context). Future
  snapshot tests could close this; not in scope here.

### Tradeoffs

- **Dotted event names for new surfaces while keeping flat names for
  existing spec §15 events** creates a minor visual inconsistency
  (some events read `cook_turn_resolved`, others read
  `ops_admin.users.detail_viewed`). Accepted because the alternative
  — renaming 40+ existing events — is a whole-codebase migration
  with no product value; the visual split is a rounding error next
  to that cost.
- **Living reference doc at `docs/telemetry/canonical-properties.md`
  must stay in sync** with future ADR updates. Mitigated by the
  synchronization-discipline rule applied to the schema doc itself:
  any change to the canonical property list requires an ADR
  amendment in the same commit.

## Notes

**Verification on first use (Phase C — ops-admin):** the 8 new
`ops_admin.*` events must each include `canonical_user_key_hash`
(when the action is user-scoped), `actor_id` (always — the admin
UUID), and `request_id`. One PR comment pastes the canonical
properties checklist; reviewer checks each emit call against it.

**Deprecation migration cadence:** reviewer-applied. When a PR
modifies a call site that still uses a deprecated name
(`canonical_key_hash`, `user_hash`), the reviewer asks the author
to rename within the same commit. No scheduled migration run.

**When this ADR itself would need revisiting:** if we add a third
observability system (e.g., Grafana for custom SQL-sourced metrics),
the schema's cross-system join key may need extension. Not imminent.

**Rejected follow-up in the same design space (documented for
history):**
1. Registering Stir's Gemini preview models in PostHog's LLM cost
   catalog so `$ai_total_cost_usd` could be auto-computed server-side
   — considered in ADR 0009, rejected there as dependency on vendor
   catalog updates. Still rejected.
2. Standardizing all AI trace ids on backend `x-request-id` instead
   of iOS-supplied feature ids — see Alternatives above; collapses
   retry semantics.
