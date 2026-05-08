# Stir telemetry — canonical property schema

**Status:** living reference, landed 2026-04-24 with ADR 0027.
Update this doc any time the schema expands or a deprecated name
migrates.

**Predecessor audit:** `docs/telemetry/2026-04-24-audit.md` (Phase A
of the telemetry wiring bundle). The findings it enumerated (G1–G12)
motivate the rules below.

---

## 1. Purpose

Single source of truth for property names, join keys, identity
binding, and synchronization discipline across every PostHog event
and every Sentry capture Stir emits. ADR 0027 is the decision; this
doc is the reference you consult while writing or reviewing telemetry
code.

Scope: backend Edge Functions + iOS + backend SQL pg_net Sentry
dispatch. NOT in scope: `docs/posthog/dashboards.json` insight
configuration, `docs/sentry/alerts.md` alert rules (those consume
this doc; they don't define it).

---

## 2. Canonical property catalog

Every property below has ONE canonical name. Use it everywhere.
Values are structured (token counts, costs, durations, enum states)
— never user free-text.

| Property                       | Type / shape                             | Applicability                                           | Notes |
|--------------------------------|------------------------------------------|---------------------------------------------------------|-------|
| `canonical_user_key_hash`      | string, 16-char SHA-256 prefix (hex)     | PostHog distinct_id + user-scoped events · Sentry tag · DB columns | See §3 identity |
| `request_id`                   | TEXT — UUID or `voice:<session>:<turn>`  | Sentry captures on request-scoped surfaces · PostHog on request-scoped surfaces | See §7 join model |
| `actor_id`                     | string — UUID (Supabase Auth user_id) for human admins · `system:<source>` for system actors (`system:cron`, future `system:webhook` etc.) | PostHog + Sentry on admin-surface emits (`ops_admin.*`) · Sentry on cron-invoked surfaces (cost-anomaly dispatch) | Source of truth for action attribution. `system:` prefix reserves namespace for non-human actors so omitting reads as "we don't know" rather than "no human actor." |
| `feature_key`                  | enum — `dinner_solve | voice_cook_turn | recipe_import | pantry_parse | substitution | grocery_generate | cook_mode_realtime | cook_turn` | PostHog on AI events (`feature` in event property; `feature_key` in DB + request-scope) | Match spec §3 |
| `tier`                         | enum — `free | premium | pro`            | PostHog on billing-relevant events · Sentry when billing state matters to the capture | Match `app_users.tier` |
| `billing_state`                | enum — `none | active | trial | grace | cancelled_active | expired` | PostHog on `entitlement_state_changed` and billing webhook emits when those ship | Match `entitlement_snapshots.billing_state` |
| `model`                        | string — `gemini-3-flash-preview | gemini-3.1-flash-lite-preview | gemini-3.1-flash-live-preview` | PostHog AI events via `recordAIRequest` (appears as `$ai_model`) | PostHog-reserved `$ai_*` properties forwarded by `ai_observability.ts` |
| `cost_usd`                     | number (USD)                             | PostHog AI events (`$ai_total_cost_usd`) · DB `ai_request_log.cost_usd` | Always server-computed; iOS never computes costs |
| `session_id`                   | UUID                                     | PostHog voice events · backend voice-turn-usage trace_id · DB `ai_request_log.session_id` | Voice-scope correlation id |
| `prompt_version`               | string — semver-ish                      | PostHog AI events · DB `ai_request_log.prompt_version`  | From `prompt_versions` table |
| `thinking_level`               | enum — `minimal | low`                   | PostHog AI events · DB `ai_request_log.thinking_level`  | Per-feature selection |
| `retry_count`                  | integer ≥ 0                              | PostHog AI events · DB                                  | Count of Gemini retries inside a single HTTP request |
| `error_code`                   | string — ErrorCode enum value            | PostHog `ai_request_failed` + terminal events · Sentry tag on captureError | Values match `_shared/errors.ts` ErrorCode |
| `endpoint`                     | string — request path                    | Sentry captureError tag                                 | iOS sends this today; backend should add when capture path exists |
| `path`                         | enum — `live_api | gemini_fallback`      | PostHog voice events only                               | Discriminates Gemini Live vs Speech fallback |
| `prompt_cached_tokens`         | integer ≥ 0                              | PostHog AI events (`$ai_cache_read_input_tokens` when >0) · DB `ai_request_log.prompt_cached_tokens` | Conditional emit |

PostHog LLM Observability reserved keys (`$ai_*`) are populated by
`_shared/ai_observability.ts` and must not be hand-assembled at call
sites. See ADR 0009.

---

## 3. Identity — `distinct_id` and `user` binding

- **PostHog `distinct_id`** = `canonical_user_key_hash` (16-char
  SHA-256 of `canonical_user_key`). Bound once per iOS session via
  `PostHogClient.shared.identify(distinctID: keyHash)` at bootstrap;
  bound per-call on backend via `hashCanonicalKey(canonical_user_key)`
  inside `recordAIRequest`. Both paths produce the same string for
  the same user.
- **Sentry `user.userId`** = same value. Set once per iOS session via
  `SentryReporter.setUserContext(keyHash:)`. Backend SQL Sentry
  dispatch attaches the hash as `tags.canonical_user_key_hash`
  (renamed from legacy `user_hash` in migration `20260424000007`,
  Phase D — see §9 Migrated names).
- **NEVER** set raw `canonical_user_key`, email, or any derived
  PII as `distinct_id` or Sentry user fields. Spec §11 redaction
  requirement.

For ops-admin emits (`ops_admin.*` surface), the `actor_id`
(admin user UUID from Supabase Auth) is a separate property — it
does NOT replace `canonical_user_key_hash` and it is NOT used as
distinct_id on that surface. Rationale: admins acting on users
produce events that belong to the ADMIN's timeline (distinct_id =
admin's hash, derived from the Supabase Auth user id) but carry
the acted-on user's hash as a property.

For **cron-invoked or other system-driven surfaces** (no human
actor, no HTTP request scope), `actor_id` is set to `system:<source>`
where `<source>` identifies the originating subsystem
(`system:cron`, future `system:webhook`, `system:worker`). This is
strictly preferred over omitting the field — omission reads as "we
don't know who acted" while `system:cron` reads as "no human acted,
the scheduler did." Cross-system joins on `actor_id` then
distinguish admin-driven events from automated ones cleanly.

---

## 4. Event naming

### 4.1 New surfaces (landed after 2026-04-24)

`<surface>.<noun>.<verb_or_state>`, dotted, past-tense, snake_case
within segments.

Examples:
- `ops_admin.users.detail_viewed`
- `ops_admin.users.quota_reset`
- `ops_admin.flagged_outputs.resolved`
- `ops_admin.prompt_versions.rollout` (noun-style verb accepted
  when the action is inherently a noun)
- Future: `billing_webhook.subscription.renewed`

Surfaces in scope of this convention: `ops_admin.*`, any future
webhook handler, any future server-emitted event outside the iOS
event allow-list.

### 4.2 Existing spec §15 events (grandfathered)

Flat form: `<subject>_<past_verb>`. `scan_submitted`,
`dinner_solve_requested`, `cook_turn_resolved`, `voice_session_refreshed`,
`app_opened`, etc. Do NOT rename. CLAUDE.md §Telemetry events is the
allow-list; `Stir/Integrations/PostHog/PostHogClient.swift`
`TelemetryEvent` enum enforces spelling.

### 4.3 PostHog-reserved events

`$ai_generation`, `$ai_trace`. Do not add more `$`-prefixed events
without vetting PostHog's LLM Analytics semantics.

---

## 5. Property naming

- **snake_case** everywhere. Sentry tags and PostHog properties
  share the same name when they represent the same field (e.g.
  `endpoint` on both sides). See §9 deprecation table for historical
  camelCase / inconsistent names that haven't migrated yet.
- **Boolean property names should read as the TRUE state.** `is_cloudkit`,
  `is_new_user`, `is_trial`, `voice_enabled` — not `not_cloudkit` /
  `trial_false`.
- **Enum values are lowercase snake_case strings.** `warn`,
  `critical`, `live_api`, `gemini_fallback` — matches the
  CLAUDE.md + spec conventions.
- **Numeric units in the name when ambiguous.** `latency_ms`,
  `latency_ttfa_ms`, `duration_ms`, `cost_usd`. Do NOT use `cost`
  with an implicit currency.
- **Never abbreviate `canonical_user_key_hash`**, even when the
  surrounding code calls its local variable `keyHash`. The Swift
  var name is internal; the emitted property name is canonical.

---

## 6. PII rules

Banned from every PostHog event property and every Sentry tag:

| Banned value                             | Where it tries to sneak in                   | Use instead |
|------------------------------------------|----------------------------------------------|-------------|
| raw `canonical_user_key`                 | Sentry `user.userId`, event properties       | `canonical_user_key_hash` |
| `actor_email`                            | ops-admin Sentry tags, audit-related emits   | `actor_id` (UUID) |
| Recipe titles                            | voice trace `$ai_input_state.recipe_title`   | `recipe_plan_id` (UUID) |
| Transcripts / spoken text                | voice turn properties                        | Token counts only |
| AI response body / `spoken_response`     | `cook_turn_resolved`, voice trace outputs    | `result_type` enum |
| Email, phone, address                    | anywhere                                     | nothing; don't collect |
| iOS device identifiers (IDFA, UUID per device) | `app_opened` properties                 | `canonical_user_key_hash` |
| Raw Authorization headers / JWTs         | Sentry context                               | strip before capture |

Banned PostHog LLM reserved fields:
- `$ai_input` (the prompt as blob) — never populated
- `$ai_output_choices` (the response as blob) — never populated

These are the reason `ai_observability.ts` uses the single-event
`/i/v0/e/` endpoint, not the multipart `/i/v0/ai` blob endpoint.
See ADR 0009.

---

## 7. Cross-system join: the dual-id model

Stir deliberately carries TWO request-scoped ids. Each serves a
different join.

| Id | Source | Stable across retries? | Joins what? |
|---|---|---|---|
| `request_id` | `_shared/logger.ts:requestIdFrom` — honors iOS-supplied `x-request-id` header, else generates UUID | No — one per physical HTTP request | Sentry ↔ Supabase function logs (same value appears on every log line for that request) |
| `$ai_span_id` / iOS feature id (`solve_request_id`, `import_id`, `session_id`, `client_request_id`, `sub_event_id`, `source_id`) | iOS request body, generated once and retried | Yes | PostHog `$ai_generation` ↔ `ai_request_log` row (both use the same value) |

Rule of thumb for reviewers:
- **If the dashboard asks "what did THE USER see?"** (one logical
  call), join on `$ai_span_id` / the feature id.
- **If the dashboard asks "what did THE BACKEND do?"** (retries,
  cache hits, errors within one HTTP call), join on `request_id`.
- **If you're correlating a Sentry error to the PostHog event it
  caused,** join on `request_id`. PostHog events should include
  `request_id` alongside the feature id for this reason; the
  two-id pattern is intentional.

### 7.1 Cron-invoked surfaces — `request_id` carve-out

Some emit surfaces have **no HTTP request scope at all** — pg_cron
jobs, Postgres triggers, scheduled background workers. There is no
`x-request-id` to carry on these surfaces; forcing a synthetic
`request_id` would be cargo-cult (the dashboard query "find the
PostHog/Sentry event for this Supabase function log line" makes no
sense when there's no function log line).

**Rule:** cron-invoked or otherwise stateless surfaces OMIT
`request_id`. In its place, the surface's **row primary key**
becomes the canonical cross-system join key for that surface. The
omission MUST be documented:

1. In the surface's row in the §8 applicability matrix below (set
   `request_id: omitted (cron carve-out — see §7.1)`).
2. In any alert rule querying that surface (`docs/sentry/alerts.md`
   should cite the row-primary-key field as the join key, not
   `request_id`).
3. Implicitly via `actor_id: system:<source>` — the presence of a
   `system:*` actor reads as "this isn't a request-scoped event."

**Surfaces this applies to today:**

| Surface | Row primary key (= cross-system join) | actor_id |
|---|---|---|
| Backend SQL Sentry — cost-anomaly dispatch (`stir_ops_cost_anomaly_alert_dispatch`) | `event_id` (= `cost_anomalies.id` UUID) | `system:cron` |

Future cron-invoked surfaces (e.g., `stir_ops_reactivation_enqueue`
notifications, retention sweeps) inherit this rule.

### 7.2 Per-surface applicability

Applicability on each emit surface:

| Surface                                  | `request_id` required? | `$ai_span_id` / feature id required? |
|------------------------------------------|------------------------|---------------------------------------|
| Backend `$ai_generation` (AI calls)      | should include (not current)  | yes (that's the contract) |
| Backend `ops_admin.*` emits (Phase C)    | **yes**                | N/A |
| Backend SQL Sentry (cost anomaly)        | omitted — see §7.1 cron carve-out (`event_id` = `cost_anomalies.id` UUID is the surface-specific join key) | N/A (no AI generation) |
| Backend handler error captures (Phase D) | **yes**                | N/A |
| iOS Sentry `captureError`                | **yes** (when request context available — all 5 current sites have it) | N/A |
| iOS Sentry `breadcrumb`                  | should include when possible | N/A |
| iOS PostHog events on backend-response paths (`ai_request_failed`, etc.) | should include | yes, feature id passed as property |
| iOS PostHog events on pure-UI state (`scan_started`, `cook_step_advanced`) | N/A (no backend request) | N/A |

---

## 8. Applicability matrix — properties per surface

| Surface                           | Mandatory                                                           | Conditional                                             |
|-----------------------------------|---------------------------------------------------------------------|---------------------------------------------------------|
| Backend `$ai_generation` (AI)     | `distinct_id` (via helper) · `$ai_span_id` · `$ai_span_name` · `$ai_model` · `$ai_provider='gemini'` · `$ai_input_tokens` · `$ai_output_tokens` · `$ai_total_cost_usd` · `$ai_latency` · `$ai_is_error` · `feature` | `$ai_cache_read_input_tokens` (when >0) · `prompt_version` · `thinking_level` · `retry_count` · `$ai_error`/`error_code` (on failure) · `path` (voice) |
| Backend `ops_admin.*` (Phase C)   | `distinct_id=<admin hash>` · `request_id` · `actor_id` (admin UUID) · `action` (the audit action string) | `canonical_user_key_hash` (when action is user-scoped) · `target_id` (feature-specific) · `result` (`ok`, `noop`, `dedup`) |
| Backend SQL Sentry (cost anomaly) | `event_id` (= `cost_anomalies.id`, the surface-specific join key — see §7.1 cron carve-out) · `level` · `logger` · `tags.anomaly_type` · `tags.severity` · `tags.canonical_user_key_hash` (renamed from `user_hash` in Phase D — migration `20260424000007`) · `tags.actor_id = 'system:cron'` | `extra` (per anomaly type) · `request_id`: **omitted** per §7.1 cron carve-out |
| Backend handler `captureError` (future Phase D work if we add SDK-Sentry) | Not applicable today — no SDK-Sentry in backend | — |
| Backend product event (server-emitted, non-AI, non-ops_admin) | `distinct_id=<user hash>` (via `hashCanonicalKey(canonical_user_key)`) · `request_id` (request-scoped log correlator — note this DOES NOT necessarily join `ai_request_log` if the emit happens before `logAIRequest()`; per-event docs MUST state whether the join works) | event-specific properties per spec §15. Example: `voice_quota_refund` (SCA-145) — `reason` mandatory, `upstream_status` conditional |
| iOS Sentry `captureError`         | `canonical_user_key_hash` (rename from `canonical_key_hash` during organic touches) · `request_id` (new; follow-up task, iOS-scope) · `endpoint` (already present on 2 sites) | `code` / `error_code` · `phase` · `auth_reason` · `field_errors` |
| iOS Sentry `breadcrumb`           | `canonical_user_key_hash` (rename pending) · `category` (Sentry native) | `screen` · `code` · `error` (string-summary) |
| iOS PostHog product events        | `distinct_id` (via identify; not per-event) | spec §15 per-event property list · `canonical_user_key_hash` is redundant-but-allowed (some events include it, fine) |

---

## 9. Deprecation table — names migrating to canonical

None of these are removed today. Migration happens at next organic
touch of the owning call site. Reviewers ask: "is this commit
touching one of these? If yes, rename in the same commit."

| Deprecated name    | Owner                                                 | Canonical name            | Migration trigger |
|--------------------|-------------------------------------------------------|---------------------------|-------------------|
| `canonical_key_hash` | iOS Sentry `captureError` + `breadcrumb` context dicts (3 `captureError` sites + 4 breadcrumb sites in `RootCoordinator.swift`, `SupabaseSessionClient.swift`, `CookModeViewModel.swift`) | `canonical_user_key_hash` | Next touch to any of those files for Sentry reasons |
| `keyHash` (Swift var name) | Local variable inside `RootCoordinator`, `SentryReporter`, `SupabaseSessionClient` | N/A — internal, no wire contract; keep | Never. The var is just a local; what matters is the PROPERTY name it produces. |
| `user.userId` (Sentry SDK binding) | `SentryReporter.setUserContext` — Sentry SDK-defined field | N/A — external contract we don't control | Keep as-is; Sentry's API, not ours to rename |

Once a row in this table is migrated, move it to a "Migrated"
section at the bottom of this file (don't delete — keep the trail).

### 9.1 Migrated names (trail — do not delete)

| Old name | New name | Owner | Migrated in | Notes |
|----------|----------|-------|-------------|-------|
| `tags.user_hash` | `tags.canonical_user_key_hash` | Backend SQL `stir_ops_cost_anomaly_alert_dispatch` Sentry event body | migration `20260424000007` (Phase D, 2026-04-24) | Same migration also added `tags.actor_id = 'system:cron'` per §3 system-actor convention. Transition window (dual-query period): **2026-04-24 → 2026-05-08**. After 2026-05-08 dashboards / saved searches / alert rules should reference only `tags.canonical_user_key_hash`; pre-cutover events under `tags.user_hash` age out of Sentry retention naturally. SCA-59 closed the dual-query period. |

#### Sentry tag deprecation timeline

Schedule for any future tag rename of the same shape (rotate dashboards 14 days post-deploy, when Sentry's index has fully populated under the new name):

| Tag | Cutover deploy | Index settle | Dashboards rotated |
|-----|----------------|--------------|--------------------|
| `tags.user_hash` → `tags.canonical_user_key_hash` | 2026-04-24 (mig `20260424000007`) | 2026-05-08 | 2026-05-08 (SCA-59) |

---

## 10. Synchronization discipline

Pattern named by this bundle: **specs, alerts, and runbooks written
ahead of code drift permanently because nothing forces sync.** The
Phase A audit found two alerts (`preamble-present-rate`,
`cloudkit-sync-error`) referencing properties not emitted by
production code, plus spec §9 listing 8 `ops_admin.*` events with
zero implementations.

Rule — applies to everyone, including future Daniel + future Claude
sessions:

1. **Adding an event to spec §15 or CLAUDE.md §Telemetry events
   without a matching emit is banned.** If the emit doesn't exist
   yet, add the event under a "## Proposed (not yet emitted)"
   subsection in CLAUDE.md with the PR / commit that will implement
   it referenced; delete from Proposed section once it lands.
2. **Adding an alert to `docs/sentry/alerts.md` without a verified
   emit source is banned.** Every alert rule's condition must cite
   the source file where the property is emitted, e.g.:
   ```markdown
   ### cloudkit-sync-error
   - **Condition:** `sync_state_changed.is_cloudkit == false` ...
   - **Emit source:** `RootCoordinator.swift:609`
   ```
   If the emit doesn't exist, the alert lands with `Emit source:
   UNIMPLEMENTED (TODO)` — grep-findable, not silent.
3. **Adding a property to `docs/posthog/dashboards.json` that isn't
   yet emitted:** OK (the existing doc explicitly uses this as a
   coverage-gap detector; see its README) — but the property must
   match an entry in this schema's catalog (§2) or appear in an
   ADR that extends it.
4. **Reviewer checklist for any telemetry-touching PR** (paste into
   review comment):
   ```
   Telemetry canonical-schema checklist:
   [ ] Every new emit includes `canonical_user_key_hash` (when user-scoped)
   [ ] Every new backend emit includes `request_id`
   [ ] Every new admin emit includes `actor_id`
   [ ] No banned PII fields (see canonical-properties.md §6)
   [ ] If this adds a spec §15 event / CLAUDE.md event, the emit
       landed in the same commit OR is in Proposed section
   [ ] If this adds an alert rule, Emit source cited
   ```

---

## 11. Implementation style — typed builders vs dict literals

The schema defines the property CONTRACT. Whether call sites
enforce it via a typed builder (like
`BillingTelemetryProperties.paywallViewed(...)`) or a dict literal
(`analytics.capture(.foo, properties: ["bar": baz])`) is an
implementation choice, not mandated here.

Current state:
- Step-5 billing events: typed builders (`BillingTelemetryProperties.swift`)
- Step-7 import + grocery + widgets: typed builders (`StepSevenTelemetry` nested enum)
- Backend `$ai_generation`: centralized in `recordAIRequest` — the single path means drift is structurally prevented
- Other iOS features (Scan, Cook Mode core, Substitution, Leftovers):
  dict literals at call sites

Typed builders are preferred for new features with >3 emit sites
in the same domain. Dict literals are acceptable for 1-2-site
domains or when a builder adds ceremony without catching drift.

Full-coverage typed-builder migration: §Deferred in CLAUDE.md.

---

## 12. Example emits (Phase C reference)

Phase C of this bundle wires 8 `ops_admin.*` events. Target shape,
conforming to this schema:

```typescript
// users.list (read-only, no writeAudit seam; emit just before response return)
capturePosthogEvent(log, {
  event: 'ops_admin.users.list_queried',
  distinctId: adminKeyHash,           // hash of admin's Supabase Auth user_id
  properties: {
    request_id: ctx.requestId,
    actor_id: ctx.admin.authUserId,
    tier_filter: params.tier ?? null,  // metadata only, never the query results
    has_search: Boolean(params.search),
    limit: params.limit ?? 50,
  },
});

// users.force_reauth (writeAudit seam exists at ops-admin/index.ts:369)
capturePosthogEvent(log, {
  event: 'ops_admin.users.force_reauth',
  distinctId: adminKeyHash,
  properties: {
    request_id: ctx.requestId,
    actor_id: ctx.admin.authUserId,
    canonical_user_key_hash: await hashCanonicalKey(params.canonical_user_key),
    target_id: params.canonical_user_key,   // for audit_log correlation
    result: 'ok',
  },
});

// flagged_outputs.resolve (three resolutions — include the resolution action)
capturePosthogEvent(log, {
  event: 'ops_admin.flagged_outputs.resolved',
  distinctId: adminKeyHash,
  properties: {
    request_id: ctx.requestId,
    actor_id: ctx.admin.authUserId,
    feature_key: flagged.feature_key,
    resolution_action: params.action,   // 'dismissed' | 'withdrawn' | 'canned_fallback_pinned'
    target_id: params.id,
  },
});
```

---

## 13. Update log

- **2026-04-24** — Schema landed with ADR 0027. Phase A audit
  (`docs/telemetry/2026-04-24-audit.md`) G1–G12 motivated the rules.
  `canonical_user_key_hash` pinned as canonical identity name;
  dual-id model for cross-system joins documented; synchronization
  discipline adopted.
- **2026-04-24 (Phase D commit 1)** — §7.1 cron-invoked surfaces
  carve-out added. `actor_id` namespace extended to `system:<source>`
  for non-human actors. §8 Backend SQL Sentry row updated to
  reference §7.1.
- **2026-04-24 (Phase D commit 2)** — Backend SQL Sentry tag
  rename `user_hash` → `canonical_user_key_hash` landed via migration
  `20260424000007_cost_anomaly_dispatch_canonical_tags.sql`. Same
  migration adds `tags.actor_id = 'system:cron'`. Row moved from §9
  deprecation table to §9.1 Migrated names trail.

Future updates: Phase F will update `docs/sentry/alerts.md` to
include `Emit source:` citations and rewrite the two drifted alerts
(G5/G6 from the audit). The iOS Sentry `canonical_key_hash` rename
(remaining row in §9 deprecation table) waits for the next organic
touch of `RootCoordinator.swift` / `SupabaseSessionClient.swift` /
`CookModeViewModel.swift` Sentry call sites.
