---
title: Stir — Ops Admin Specification
status: phase-1-built (not yet prod-deployed at spec-write)
spec_type: supplementary
parent_spec: Stir - Full App Specification.md
created: 2026-04-24
phase_markers:
  - "[Phase 1 — built]"
  - "[Phase 2 — contracted, iOS half pending]"
  - "[Phase 3 — deferred]"
confidence_tags:
  - "(fact)"
  - "(inference)"
  - "(uncertain)"
tags:
  - ops-admin
  - backend
  - spa
  - supabase
---

# Stir — Ops Admin Specification

> **Merged from two independent ChatGPT Pro responses on 2026-04-24.** Facts are convergent across both sources; structural choices reflect the better organization from each. See Appendix A for source lineage.

## 1. Overview

Ops Admin is Stir's internal operational layer for reviewing flagged AI outputs, investigating cost anomalies, resetting user quotas, forcing user re-authentication, toggling feature flags, rolling out prompt versions, and inspecting audit trails. (fact)

The Phase 1 implementation is built on origin/main and is not yet deployed to the prod Supabase project at spec-write time. (fact)

Ops Admin is a read/write surface over operational tables only. (fact)

Ops Admin reads user rows, entitlement snapshots, AI request logs, voice session metadata, flagged outputs, cost anomalies, notification queue status, device installation metadata, and audit rows. (fact)

Ops Admin writes operational state through audit rows, flagged-output resolution fields, `app_users.reauth_required_at`, `usage_counters.used_count`, `feature_flags`, and `prompt_versions`. (fact)

Ops Admin does not write user content because recipes, pantry items, and meal plans live in CloudKit and are never admin-writable. (fact)

Ops Admin is not a customer-support-agent tool; it assumes a technical operator who reads `canonical_user_key` values, raw JSON, enum keys, and operational metadata directly. (fact)

A customer-support-agent variant is Phase 3+ scope. (fact)

Ops Admin is not billing infrastructure. Refunds, subscription overrides, and email composition are out of scope. (fact)

RevenueCat and Apple are authoritative for billing per Stir full spec §9. (fact)

Admins authenticate through Supabase Auth magic links, and iOS users authenticate through the distinct `/v1/session/bootstrap` path. (fact)

The admin and iOS paths share the HS256 secret but are gated separately at the Edge Function boundary per ADR 0023. (fact)

The admin surface is a web SPA intended for the admin's laptop. (fact)

The SPA is not a product surface and has no push notifications, background sync, or offline mode. (fact)

| Phase marker | Meaning |
|---|---|
| `[Phase 1 — built]` | Landed in the step-8 bundle on origin/main; not necessarily deployed to prod Supabase at spec-write time. (fact) |
| `[Phase 2 — contracted, iOS half pending]` | Backend contract landed; iOS source for reauth and flag-output UI landed in `d6cea70`, but iOS has not shipped to TestFlight or App Store at spec-write time. (fact) |
| `[Phase 3 — deferred]` | Tracked in `CLAUDE.md §Deferred` with explicit triggers and outside current implementation scope. (fact) |

## 2. Entity catalog

All ops-owned tables in §2.1 through §2.5 exist on origin/main. (fact)

RLS is enabled on every ops-owned table, and admin-gated policies reference `public.is_admin()`. (fact)

Sections §2.6 through §2.16 cover read or write surfaces used by Ops Admin but not fully specified by DDL in the supplied material; only columns named in source material are listed for these partially specified tables. (fact)

The SPA reads and mutates most data through admin RPCs or Edge Function actions rather than direct table access. (fact)

### 2.1 ops_admins [Phase 1 — built]

`ops_admins` links Supabase Auth users to Stir's admin role; presence of a row grants admin status. (fact)

Provisioning is manual through SQL editor `INSERT`. (fact)

The `ops_admins_self_select` RLS policy allows an authenticated user to select only their own row, which the SPA uses as its "am I admin?" probe. (fact)

There are no UPDATE, INSERT, or DELETE policies. Lifecycle outside SELECT goes through SQL editor or an unspecified service-role Edge Function. (fact)

No retention policy is specified for `ops_admins`. (fact)

Migration: `20260423000004_init_ops_admins.sql`. (fact)

| Column | Type | Null | Description |
|---|---|---|---|
| `auth_user_id` | `UUID` | No | Primary key referencing `auth.users(id)` with `ON DELETE RESTRICT`. (fact) |
| `email` | `TEXT` | No | Admin email for support-time lookup and provisioning traceability. (fact) |
| `created_at` | `TIMESTAMPTZ` | No | Row creation timestamp with default `now()`. (fact) |
| `notes` | `TEXT` | Yes | Manual notes for the admin row. (fact) |

Indexes: `idx_ops_admins_email` on `email`. (fact)

### 2.2 is_admin() [Phase 1 — built]

`public.is_admin()` is a `SECURITY DEFINER STABLE` plpgsql function that reads `auth.uid()` and checks membership in `ops_admins`. (fact)

The function fail-closes on any exception. (fact)

The exception branch specifically handles `SQLSTATE 22P02`, which occurs when an iOS session JWT has a non-UUID `sub` value and that value fails the UUID cast. (fact)

The function emits `RAISE WARNING` on exception so unexpected branches appear in Postgres logs. (fact)

Ops-table RLS policies and admin RPC inner gates use `is_admin()`. (fact)

| Aspect | Value |
|---|---|
| Input | None; relies on `auth.uid()` rather than an explicit SQL argument. (fact) |
| Return | Boolean — whether the current authenticated Supabase Auth user has an `ops_admins` row. (fact) |

### 2.3 ops_flagged_outputs [Phase 1 — built]

`ops_flagged_outputs` is the AI output review queue. (fact)

The table is populated by iOS user reports, admin-originated inserts, and a reserved system source for hard-rule validator failures. (fact)

The currently built caller is the iOS user flag endpoint via `POST /v1/ops/flag-output`. The admin-originated UI is Phase 3 deferred (backend service-role inserts with `flagged_by='admin'` are accepted). System auto-detection has no current caller. (fact)

The table stores a SHA-256 hash of `canonical_user_key` truncated to 16 hex characters, not the raw key. (fact)

Admin support flows recover raw user identity through `request_id` lookup in `ai_request_log.canonical_user_key`. (fact)

Rows deduplicate forever on `(canonical_user_key_hash, request_id)`. Re-flagging the same AI call after the original flag resolves creates no new row. (fact)

The handler catches Postgres error code `23505` and returns the existing row id with `dedup=true`. (fact)

Retention is indefinite for resolved and unresolved rows; no auto-trim exists for flagged outputs. (fact)

Migration lineage: `20260423000006_init_ops_flagged_outputs.sql`, `20260424000002_request_id_text_consolidation.sql`, `20260424000005_input_validation_size_caps.sql`. (fact)

| Column | Type | Null | Description |
|---|---|---|---|
| `id` | `UUID` | No | Primary key with default `gen_random_uuid()`. (fact) |
| `canonical_user_key_hash` | `TEXT` | No | SHA-256 hash prefix (16 hex chars) for the owning canonical user key. (fact) |
| `feature_key` | `TEXT` | No | Feature that produced the AI output. (fact) |
| `request_id` | `TEXT` | No | AI request identifier; accepts UUID-shaped values and `voice:<session>:<turn>` values after migration `20260424000002`. (fact) |
| `flagged_by` | `ops_flag_source` | No | Source of the flag. (fact) |
| `flag_reason` | `TEXT` | No | User, admin, or system reason; max 500 chars. (fact) |
| `context_snapshot_json` | `JSONB` | Yes | Small contextual payload; SQL CHECK + Zod size cap of 4096 bytes. (fact) |
| `raw_input_json` | `JSONB` | Yes | Owner-scoped raw AI input snapshot when lookup succeeds. (fact) |
| `raw_output_json` | `JSONB` | Yes | Owner-scoped cached AI output snapshot when lookup succeeds. (fact) |
| `created_at` | `TIMESTAMPTZ` | No | Row creation timestamp with default `now()`. (fact) |
| `resolved_at` | `TIMESTAMPTZ` | Yes | Resolution timestamp. (fact) |
| `resolved_by` | `UUID` | Yes | Resolving admin auth user id; references `auth.users(id)` with `ON DELETE SET NULL`. (fact) |
| `resolution_action` | `ops_flag_resolution_action` | Yes | Resolution action applied by the admin. (fact) |
| `resolution_notes` | `TEXT` | Yes | Admin notes for resolution. (fact) |
| `canned_fallback_json` | `JSONB` | Yes | Admin-pinned response body for `canned_fallback_pinned`; SQL CHECK + Zod cap 65536 bytes. (fact) |

The resolution consistency constraint requires unresolved rows to have no resolution fields, and requires `canned_fallback_json` only when `resolution_action='canned_fallback_pinned'`. (fact)

The unique index `idx_ops_flagged_outputs_dedup` covers `(canonical_user_key_hash, request_id)`. (fact)

| Enum | Value | Phase | Meaning |
|---|---|---|---|
| `ops_flag_source` | `user` | `[Phase 1 — built]` | iOS user submitted the report through `/v1/ops/flag-output`. (fact) |
| `ops_flag_source` | `admin` | `[Phase 3 — deferred]` | Admin-originated flag; backend service-role insert shape exists, UI button not shipped. (fact) |
| `ops_flag_source` | `system` | `[Phase 3 — deferred]` | System auto-detection from hard-rule validators; no current caller. (fact) |
| `ops_flag_resolution_action` | `dismissed` | `[Phase 1 — built]` | Passive review with no cache mutation. (fact) |
| `ops_flag_resolution_action` | `withdrawn` | `[Phase 1 — built]` | Deletes matching `ai_response_cache` row after owner-scoped lookup. (fact) |
| `ops_flag_resolution_action` | `canned_fallback_pinned` | `[Phase 1 — built]` | Replaces matching cached response body with admin-supplied JSON. (fact) |

### 2.4 audit_log [Phase 1 — built]

`audit_log` is the append-only record of admin mutations that change state observable to users. (fact)

The table also records targeted user-detail reads with `action='users.detail.viewed'` and null `before_json`/`after_json`. (fact)

Authenticated admins can SELECT audit rows through the `audit_log_admin_select` RLS policy. (fact)

There is no UPDATE policy and no DELETE policy. Clearing an audit mistake uses a compensating entry, not deletion. (fact)

Writes are service-role writes through `_shared/audit.ts::writeAudit`. (fact)

Audit rows retain `actor_email` for support-time lookup; telemetry uses `actor_id` to avoid email PII. (fact)

Retention is 90 days through the nightly `stir-audit-log-retention` pg_cron job at 09:30 UTC. The retention posture follows the `webhook_log` precedent from migration `20260419000002`. (fact)

Migration: `20260423000007_init_audit_log.sql`. (fact)

| Column | Type | Null | Description |
|---|---|---|---|
| `id` | `UUID` | No | Primary key with default `gen_random_uuid()`. (fact) |
| `actor_id` | `UUID` | Yes | Admin auth user id; references `auth.users(id)` with `ON DELETE SET NULL`. (fact) |
| `actor_email` | `TEXT` | Yes | Admin email retained for support-time lookup. (fact) |
| `action` | `TEXT` | No | Dotted action string, max 128 chars. (fact) |
| `target_table` | `TEXT` | No | Target table name, max 128 chars. (fact) |
| `target_id` | `TEXT` | No | Target identifier, max 256 chars. (fact) |
| `before_json` | `JSONB` | Yes | Pre-mutation state when supplied. (fact) |
| `after_json` | `JSONB` | Yes | Post-mutation state when supplied. (fact) |
| `request_id` | `TEXT` | Yes | Request id; migrated from UUID to TEXT in `20260424000002`. (fact) |
| `created_at` | `TIMESTAMPTZ` | No | Audit timestamp with default `now()`. (fact) |

| Index | Columns | Purpose |
|---|---|---|
| `idx_audit_log_created_at` | `created_at DESC` | Recent audit browsing. (fact) |
| `idx_audit_log_actor` | `actor_id, created_at DESC` where `actor_id IS NOT NULL` | Actor-scoped audit lookup. (fact) |
| `idx_audit_log_target` | `target_table, target_id, created_at DESC` | Target-scoped audit lookup. (fact) |
| `idx_audit_log_action` | `action, created_at DESC` | Action-scoped audit lookup. (fact) |

### 2.5 cost_anomalies [Phase 1 — built]

`cost_anomalies` stores detector outputs from `stir_ops_cost_anomaly_scan()`. The scan runs every 15 minutes through the `stir-cost-anomaly-scan` pg_cron job. (fact)

Rows are dispatched to Sentry through a two-phase dispatch and confirmation system storing `dispatched_at`, `sentry_request_id`, `confirmed_at`, and `confirm_attempts`. (fact)

RLS allows authenticated admins to SELECT and UPDATE through `is_admin()`. Service-role code can INSERT and DELETE rows. (fact)

Per-type per-user deduplication uses `NOT EXISTS` filters over a 24-hour window. Resolving an anomaly opens the door to a fresh alert on the next scan tick. (fact)

The table has resolution columns (`resolved_at`, `resolved_by`), but no `cost_anomalies.resolve` API action or SPA resolve control is specified in the supplied action list — see §Gaps. (fact)

Legacy `alerted_at` was migrated into `dispatched_at` and `confirmed_at` in migration `20260424000004`; pre-existing rows were backfilled from the old value. (fact)

No explicit retention period for `cost_anomalies` is specified. (fact)

Migration lineage: `20260423000008_init_cost_anomalies.sql`, `20260424000004_cost_anomaly_two_phase_dispatch.sql`. (fact)

| Column | Type | Null | Description |
|---|---|---|---|
| `id` | `UUID` | No | Primary key with default `gen_random_uuid()`. (fact) |
| `canonical_user_key_hash` | `TEXT` | No | SHA-256 hash prefix for the user associated with the anomaly. (fact) |
| `anomaly_type` | `cost_anomaly_type` | No | Type of anomaly detected. (fact) |
| `severity` | `cost_anomaly_severity` | No | Severity level. (fact) |
| `details_json` | `JSONB` | No | Per-type details payload. (fact) |
| `detected_at` | `TIMESTAMPTZ` | No | Detector timestamp with default `now()`. (fact) |
| `dispatched_at` | `TIMESTAMPTZ` | Yes | Phase-1 Sentry dispatch timestamp. (fact) |
| `sentry_request_id` | `BIGINT` | Yes | `pg_net` request handle. (fact) |
| `confirmed_at` | `TIMESTAMPTZ` | Yes | Phase-2 Sentry confirmation timestamp or give-up timestamp after retry cap. (fact) |
| `confirm_attempts` | `INTEGER` | No | Confirmation retry counter with default 0. (fact) |
| `resolved_at` | `TIMESTAMPTZ` | Yes | Admin resolution timestamp. (fact) |
| `resolved_by` | `UUID` | Yes | Resolving admin auth user id; references `auth.users(id)` with `ON DELETE SET NULL`. (fact) |

| Enum | Value | Phase | Meaning |
|---|---|---|---|
| `cost_anomaly_type` | `daily_spend_2x` | `[Phase 1 — built]` | Premium user above $3/day or Pro user above $8/day. (fact) |
| `cost_anomaly_type` | `daily_spend_hard_cap` | `[Phase 1 — built]` | Any user above $10/day regardless of tier. (fact) |
| `cost_anomaly_type` | `voice_session_tokens_over_cap` | `[Phase 1 — built]` | Voice session with cumulative prompt tokens above 50000 across turns. (fact) |
| `cost_anomaly_type` | `runaway_session` | `[Phase 3 — deferred]` | Reserved for session above 10 minutes and above 20 turns; detector pending. (fact) |
| `cost_anomaly_severity` | `warn` | `[Phase 1 — built]` | Warning-level anomaly. (fact) |
| `cost_anomaly_severity` | `critical` | `[Phase 1 — built]` | Critical anomaly. (fact) |

### 2.6 app_users [Phase 1 — built read/write source]

`app_users` is the canonical operational user table used by Ops Admin for user search, detail, status changes, and reauth invalidation. (fact)

The SPA reads `app_users` through `stir_ops_list_users` and `stir_ops_user_detail` RPCs, not by direct table access. (fact)

The `users.force_reauth` action writes `reauth_required_at` on the target row and on rows whose `merged_into` points at the target. (fact)

The `users.status` action allows `active` and `banned` updates and forbids `merged` at the API layer. (fact)

Source-table RLS posture for `app_users` is not supplied. (fact)

| Column | Type | Null | Description |
|---|---|---|---|
| `canonical_user_key` | not supplied | not supplied | User key used by ops search, detail, reauth, status, and quota actions. (fact) |
| `tier` | not supplied | not supplied | User tier returned by list/detail surfaces; known API filter values are `free`, `premium`, `pro`. (fact) |
| `merged_into` | not supplied | Yes | Alias-forwarding pointer used by force-reauth cascade. (fact) |
| `reauth_required_at` | not supplied | Yes | Timestamp that invalidates session JWTs with older `iat` values. (fact) |
| `status` | not supplied | not supplied | User status; supplied values are `active`, `banned`, `merged`. Admin status mutation accepts only `active` and `banned`. (fact) |
| `last_seen_at` | not supplied | not supplied | Last-seen timestamp returned in list surfaces. (fact) |

| `app_users.status` value | Phase | Meaning |
|---|---|---|
| `active` | `[Phase 1 — built]` | User is active. (fact) |
| `banned` | `[Phase 1 — built]` | User is banned through `users.status`. (fact) |
| `merged` | `[Phase 1 — built read state]` | User row is merged; admin status API forbids setting this value. (fact) |

### 2.7 entitlement_snapshots [Phase 1 — built read source]

`entitlement_snapshots` provides billing-state and tier data in `stir_ops_user_detail`. (fact)

Ops Admin reads this surface and does not override billing. RevenueCat and Apple remain authoritative per Stir full spec §9. (fact)

Source-table RLS posture for `entitlement_snapshots` is not supplied. (fact)

| Column | Type | Null | Description |
|---|---|---|---|
| `billing_state` | not supplied | not supplied | Billing state with known values `none`, `active`, `trial`, `grace`, `cancelled_active`, `expired`. (fact) |
| `tier` | not supplied | not supplied | Entitlement tier returned in user detail. (fact) |
| `current_period_end` | not supplied | not supplied | Current entitlement period end returned in user detail. (fact) |

| `billing_state` value | Phase | Meaning |
|---|---|---|
| `none` | `[Phase 1 — built read value]` | No billing entitlement state. (fact) |
| `active` | `[Phase 1 — built read value]` | Active billing entitlement. (fact) |
| `trial` | `[Phase 1 — built read value]` | Trial billing entitlement. (fact) |
| `grace` | `[Phase 1 — built read value]` | Grace-period billing entitlement. (fact) |
| `cancelled_active` | `[Phase 1 — built read value]` | Cancelled subscription remains active until period end. (fact) |
| `expired` | `[Phase 1 — built read value]` | Expired billing entitlement. (fact) |

### 2.8 usage_counters [Phase 1 — built write source]

`usage_counters` is the quota counter table affected by `users.reset_quota`. (fact)

`users.reset_quota` zeros `used_count` for the current period and target feature. (fact)

The supplied material does not provide DDL, RLS posture, period columns, or indexes for `usage_counters`. (fact)

| Column | Type | Null | Description |
|---|---|---|---|
| `canonical_user_key` | not supplied | not supplied | User key used to target quota reset. (inference) |
| `feature_key` | not supplied | not supplied | Feature whose quota is reset. (fact) |
| `used_count` | not supplied | not supplied | Counter set to zero for the current period. (fact) |
| current-period discriminator | not supplied | not supplied | Reset targets the current period, but the period column name is not supplied. (fact) |

| Reset feature key | Phase | Meaning |
|---|---|---|
| `dinner_solve` | `[Phase 1 — built]` | Dinner solve quota feature. (fact) |
| `voice_cook_session` | `[Phase 1 — built]` | Voice cook session quota feature. (fact) |
| `recipe_import` | `[Phase 1 — built]` | Recipe import quota feature. (fact) |

### 2.9 ai_request_log [Phase 1 — built read source]

`ai_request_log` is the primary read surface for recent AI calls, cost summaries, flagged-output owner scoping, and voice-session aggregation. (fact)

`request_id` is TEXT after migration `20260424000002`. (fact)

`session_id` is UUID and voice-only after migration `20260424000003`. (fact)

A partial index exists on `(feature_key, session_id, created_at DESC)` for voice rows. (fact)

Source-table RLS posture for `ai_request_log` is not supplied. (fact)

| Column | Type | Null | Description |
|---|---|---|---|
| `request_id` | `TEXT` | not supplied | AI request id used by flags, cache lookup, audit references, and voice-derived ids. (fact) |
| `canonical_user_key` | not supplied | not supplied | Raw user key used to owner-scope cache mutations and raw snapshot lookups. (fact) |
| `feature_key` | not supplied | not supplied | Feature associated with the AI request. (fact) |
| `model` | not supplied | not supplied | AI model returned in recent request logs. (fact) |
| `cost_usd` | not supplied | not supplied | Request cost used by user detail and cost anomaly scans. (fact) |
| `latency_ms` | not supplied | not supplied | Request latency returned in recent request logs. (fact) |
| `session_id` | `UUID` | Yes for non-voice rows | Voice-only session id populated by voice-turn usage. (fact) |
| `created_at` | not supplied | not supplied | Timestamp used by recent request logs and index ordering. (fact) |

### 2.10 ai_response_cache [Phase 1 — built mutation source]

`ai_response_cache` stores cached AI response bodies used by retry flows. (fact)

`flagged_outputs.resolve` deletes cache rows for `withdrawn` and updates `response_body` for `canned_fallback_pinned`. (fact)

Every cache mutation is scoped by both `canonical_user_key` and `request_id`. The raw `canonical_user_key` is recovered from `ai_request_log` because `ops_flagged_outputs` stores only the hash. (fact)

The supplied material does not provide full DDL, RLS posture, indexes, or retention details beyond the existence of `stir-ai-response-cache-retention`. (fact)

| Column | Type | Null | Description |
|---|---|---|---|
| `canonical_user_key` | not supplied | not supplied | Owner key used to scope cache mutation. (fact) |
| `request_id` | not supplied | not supplied | Request id used to select the cached response. (fact) |
| `response_body` | not supplied | not supplied | Cached response body replaced during `canned_fallback_pinned`. (fact) |

### 2.11 voice_session_owners [Phase 1 — built read source]

`voice_session_owners` binds voice session ids to canonical user keys. ADR 0017 defines the IDOR binding for this table. (fact)

Ops Admin reads voice-session metadata and lists aggregated voice sessions through an admin action. (fact)

Source-table RLS posture for `voice_session_owners` is not supplied. (fact)

| Column | Type | Null | Description |
|---|---|---|---|
| `session_id` | not supplied | not supplied | Voice session identifier. (fact) |
| `canonical_user_key` | not supplied | not supplied | Owner user key. (fact) |
| `created_at` | not supplied | not supplied | Session creation timestamp. (fact) |
| `closed_at` | not supplied | Yes | Session close timestamp. (fact) |

### 2.12 notification_jobs [Phase 1 — built read source; enqueue write gap]

`notification_jobs` stores push-send and recipe-import-async jobs with attempt count, state, and schedule metadata. (fact)

Ops Admin reads queue status. (fact)

The overview lists `notification_jobs` enqueue as an admin write surface, but the supplied Phase 1 admin action list contains no enqueue action. This spec treats `notification_jobs` as read-only from Phase 1 ops SPA and admin router until an enqueue endpoint is specified — see §Gaps. (uncertain)

Source-table RLS posture for `notification_jobs` is not supplied. (fact)

| Column | Type | Null | Description |
|---|---|---|---|
| job kind | not supplied | not supplied | Supplied job families are `push_send` and `recipe_import_async`. (fact) |
| `attempt_count` | not supplied | not supplied | Number of delivery or processing attempts. (fact) |
| `state` | not supplied | not supplied | Queue state. (fact) |
| `scheduled_at` | not supplied | not supplied | Scheduled processing time. (fact) |

### 2.13 device_installations [Phase 1 — built read source]

`device_installations` stores device notification metadata read by ops. (fact)

Ops Admin reads device installation state and does not mutate it in the supplied admin action list. (fact)

Source-table RLS posture for `device_installations` is not supplied. (fact)

| Column | Type | Null | Description |
|---|---|---|---|
| `push_token` | not supplied | not supplied | APNs push token. (fact) |
| `apns_environment` | not supplied | not supplied | APNs environment for the token. (fact) |
| `notification_prefs_json` | not supplied | not supplied | Notification preferences payload. (fact) |

### 2.14 feature_flags [Phase 1 — built backend action; Phase 3 — deferred UI]

`feature_flags` is updated by the `feature_flags.update` admin action. (fact)

The SPA route `/flags` is a Phase 3 deferred stub. (fact)

The action updates `value`, `is_enabled`, and `rollout_pct` when supplied. (fact)

The action returns `{ noop: true, audit_id: null }` when all optional update fields are omitted. (fact)

The supplied material does not provide table DDL, RLS posture, constraints, indexes, or the full flag value schema. (fact)

| Column | Type | Null | Description |
|---|---|---|---|
| `key` | not supplied | not supplied | Feature flag key targeted by the update action. (fact) |
| `value` | not supplied | not supplied | Arbitrary flag value accepted by the action as `unknown`. (fact) |
| `is_enabled` | not supplied | not supplied | Boolean enabled state accepted by the action. (fact) |
| `rollout_pct` | not supplied | not supplied | Rollout percentage constrained by the action to 0..100. (fact) |

### 2.15 prompt_versions [Phase 1 — built backend action; Phase 3 — deferred UI]

`prompt_versions` is updated by the `prompt_versions.rollout` admin action. (fact)

The SPA route `/prompts` is a Phase 3 deferred stub. (fact)

When `is_default=true`, the action clears `is_default` on sibling versions to maintain a single-default invariant. (fact)

The supplied material does not provide table DDL, RLS posture, constraints, indexes, or transactional details for the single-default update. (fact)

| Column | Type | Null | Description |
|---|---|---|---|
| `feature_key` | not supplied | not supplied | Feature whose prompt version is being rolled out. (fact) |
| `version` | not supplied | not supplied | Prompt version targeted by rollout. (fact) |
| `rollout_pct` | not supplied | not supplied | Rollout percentage constrained to 0..100. (fact) |
| `is_default` | not supplied | not supplied | Default-version marker controlled by the rollout action. (fact) |

### 2.16 webhook_log [Phase 1 — built read source]

`webhook_log` appears in `users.detail` as webhook history. (fact)

A pre-step-8 retention job trims webhook logs. Migration `20260419000002` is the retention precedent for the audit log trim. (fact)

The supplied material does not provide DDL, RLS posture, columns returned in user detail, or retention schedule for `webhook_log`. (fact)

| Column | Type | Null | Description |
|---|---|---|---|
| webhook history fields | not supplied | not supplied | Returned by `users.detail`, but field names are not supplied. (fact) |

## 3. API surface

Every endpoint in this section lives under Supabase Edge Functions. (fact)

Admin requests use Supabase Auth magic-link JWTs and the `ops_admins` row gate. (fact)

User flag requests use iOS session JWTs through `verifySessionJWT`. (fact)

### 3.1 POST /v1/ops/admin [Phase 1 — built]

| Aspect | Value |
|---|---|
| Method | `POST`. (fact) |
| Path | `/v1/ops/admin`. (fact) |
| Auth gate | Supabase Auth magic-link JWT plus `ops_admins` membership through `verifyAdminAuth`. (fact) |

The endpoint is a single router with body shape `{ action: <enum>, params: <per-action object> }`. (fact)

The router validates request bodies through a strict Zod discriminated union on `action`. Unknown actions fail at the schema boundary with `VAL-01`. (fact)

The dispatch switch has an exhaustiveness default guard that throws with the action string if reached. (fact)

The endpoint has 11 Phase 1 built actions. (fact)

Every mutation attempts to write an audit row through `_shared/audit.ts::writeAudit`. Audit writes are non-throwing — an audit-write failure does not unwind the user-visible mutation and is logged at warn level with `request_id` and `actor_id`. (fact)

The endpoint uses IP rate limit bucket `ip:ops_admin_hourly` with 1800 requests per hour per source IP. The rate limiter landed in `_shared/rate_limiter.ts`. (fact)

Successful responses have shape `{ ok: true, ...payload, audit_id?: uuid }`. (fact)

Failure responses have shape `{ error: "<code>", message: "<str>", reason?: "<str>", field_errors?: [...] }`. (fact)

#### 3.1.1 Action catalog

| Action | Phase | Params | Returns | Audit action |
|---|---|---|---|---|
| `users.list` | `[Phase 1 — built]` | `tier?`, `search?`, `limit?`, `offset?` | Paginated users with tier, billing state, status, 30-day AI cost, open flag count, reauth timestamp, last-seen timestamp. (fact) | None specified for list reads. (fact) |
| `users.detail` | `[Phase 1 — built]` | `canonical_user_key` | Full user profile, entitlement, usage counters, recent AI request logs, webhook history, open flag count. (fact) | `users.detail.viewed`. (fact) |
| `users.reset_quota` | `[Phase 1 — built]` | `canonical_user_key`, `feature_key` | Reset result for the current quota period. (fact) | `users.reset_quota`. (fact) |
| `users.status` | `[Phase 1 — built]` | `canonical_user_key`, `status` | Updated status result. (fact) | `users.status.updated`. (fact) |
| `users.force_reauth` | `[Phase 1 — built backend; Phase 2 — iOS half pending]` | `canonical_user_key` | `reauth_required_at`, `merged_siblings_bumped`. (fact) | `users.force_reauth`. (fact) |
| `flagged_outputs.list` | `[Phase 1 — built]` | `state?`, `feature_key?`, `limit?`, `offset?` | Flagged-output rows. (fact) | None specified for list reads. (fact) |
| `flagged_outputs.resolve` | `[Phase 1 — built]` | `id`, `action`, `resolution_notes?`, `canned_fallback_json?` | Resolved row result and optional audit id. (fact) | `flagged_outputs.resolved.<action>` (inferred from supplied audit example `flagged_outputs.resolved.withdrawn`). (inference) |
| `cost_anomalies.list` | `[Phase 1 — built]` | `resolved?`, `severity?`, `since_iso?`, `limit?` | Cost anomaly rows. (fact) | None specified for list reads. (fact) |
| `voice_sessions.list` | `[Phase 1 — built backend]` | `since_iso?`, `min_tokens?`, `limit?` | Voice sessions aggregated by `session_id`, currently derived by `split_part(request_id, ':', 2)` until the deferred rewrite. (fact) | None specified. (fact) |
| `prompt_versions.rollout` | `[Phase 1 — built backend; Phase 3 — deferred UI]` | `feature_key`, `version`, `rollout_pct`, `is_default?` | Prompt-version rollout result. (fact) | `prompt_versions.rollout`. (fact) |
| `feature_flags.update` | `[Phase 1 — built backend; Phase 3 — deferred UI]` | `key`, `value?`, `is_enabled?`, `rollout_pct?` | Update result or `{ noop: true, audit_id: null }`. (fact) | `feature_flags.updated` unless noop. (fact) |

#### 3.1.2 Param schema constraints

The `users.list` schema constrains `tier` to `free`, `premium`, or `pro`; `search` to length ≤256; `limit` to 1..200; `offset` to ≥0. (fact)

The `users.detail` schema constrains `canonical_user_key` to length 4..300. (fact)

The `users.reset_quota` schema constrains `feature_key` to `dinner_solve`, `voice_cook_session`, or `recipe_import`. (fact)

The `users.status` schema allows `active` and `banned` and rejects `merged` through Zod. (fact)

The `flagged_outputs.resolve` schema requires `canned_fallback_json` only for `canned_fallback_pinned` and caps serialized fallback JSON at 64 KiB. (fact)

The `voice_sessions.list` schema caps `limit` at 500. (fact)

The `prompt_versions.rollout` and `feature_flags.update` schemas constrain rollout percentages to 0..100. (fact)

#### 3.1.3 Request examples

```json
{ "action": "users.list", "params": { "tier": "pro", "search": "ck_live_8gJ9k2", "limit": 50, "offset": 0 } }
```

```json
{ "action": "users.detail", "params": { "canonical_user_key": "ck_live_8gJ9k2mP4qR7" } }
```

```json
{ "action": "users.reset_quota", "params": { "canonical_user_key": "ck_live_8gJ9k2mP4qR7", "feature_key": "voice_cook_session" } }
```

```json
{ "action": "users.status", "params": { "canonical_user_key": "ck_live_8gJ9k2mP4qR7", "status": "banned" } }
```

```json
{ "action": "users.force_reauth", "params": { "canonical_user_key": "ck_live_8gJ9k2mP4qR7" } }
```

```json
{ "action": "flagged_outputs.list", "params": { "state": "open", "feature_key": "cook_turn", "limit": 50, "offset": 0 } }
```

```json
{ "action": "flagged_outputs.resolve", "params": { "id": "4cbaf0ba-45c1-46fe-9eb6-099a9873e1b0", "action": "withdrawn", "resolution_notes": "Unsafe substitution; force regeneration." } }
```

```json
{ "action": "cost_anomalies.list", "params": { "resolved": false, "severity": "critical", "since_iso": "2026-04-24T00:00:00Z", "limit": 50 } }
```

```json
{ "action": "voice_sessions.list", "params": { "since_iso": "2026-04-23T00:00:00Z", "min_tokens": 50000, "limit": 100 } }
```

```json
{ "action": "prompt_versions.rollout", "params": { "feature_key": "dinner_solve", "version": "2026-04-24.safe-v3", "rollout_pct": 25, "is_default": false } }
```

```json
{ "action": "feature_flags.update", "params": { "key": "cook_mode_realtime_kill_switch", "is_enabled": false, "rollout_pct": 0 } }
```

#### 3.1.4 Representative success response

```json
{
  "ok": true,
  "reauth_required_at": "2026-04-24T15:42:18.120Z",
  "merged_siblings_bumped": 2,
  "audit_id": "8fb6fc28-d637-48bf-92c1-8fd8f2e61f34"
}
```

#### 3.1.5 Error surface

| Code | HTTP | Condition |
|---|---|---|
| `VAL-01` | 400 | Zod validation failure with `field_errors`. (fact) |
| `VAL-01` | 404 | User, flagged output, feature flag, or prompt version not found. (fact) |
| `VAL-01` | 409 | Flagged output is already resolved. (fact) |
| `AUTH-01` | 401 | Missing, expired, malformed, signature-invalid, stale, reauth-required, or wrong-issuer JWT. (fact) |
| `BILL-01` | 403 | JWT is valid but user is not an admin. (fact) |
| `RATE-01` | 429 | `ip:ops_admin_hourly` bucket exhausted. (fact) |
| `NET-01` | 500 | Unknown error with sanitized response body and raw DB message logged at error level. (fact) |
| `METHOD-NOT-ALLOWED-01` | 405 | Non-POST request. (fact) |

#### 3.1.6 Error examples

```json
{ "error": "VAL-01", "message": "Invalid request body.", "field_errors": [{ "field": "params.limit", "issue": "Number must be less than or equal to 200." }] }
```

```json
{ "error": "VAL-01", "message": "User not found." }
```

```json
{ "error": "VAL-01", "message": "Flagged output already resolved." }
```

```json
{ "error": "AUTH-01", "message": "Authentication failed.", "reason": "wrong_issuer" }
```

```json
{ "error": "BILL-01", "message": "Not authorized for ops admin.", "reason": "not_admin" }
```

```json
{ "error": "RATE-01", "message": "Rate limit exceeded." }
```

```json
{ "error": "NET-01", "message": "Internal server error." }
```

```json
{ "error": "METHOD-NOT-ALLOWED-01", "message": "Method not allowed." }
```

### 3.2 POST /v1/ops/flag-output [Phase 1 — built]

| Aspect | Value |
|---|---|
| Method | `POST`. (fact) |
| Path | `/v1/ops/flag-output`. (fact) |
| Auth gate | iOS session JWT through `verifySessionJWT`; admin JWTs are not the intended auth path. (fact) |

The endpoint lets an iOS user report a bad AI output. It is not an admin endpoint. (fact)

The endpoint creates an `ops_flagged_outputs` row with `flagged_by='user'`. (fact)

The handler computes `canonical_user_key_hash` from the session claim's `canonical_user_key`. (fact)

The handler owner-scopes raw input/output snapshot lookups by `canonical_user_key`. If the `ai_request_log` or `ai_response_cache` lookup fails, the flag row is still created with null raw snapshot columns. (fact)

The endpoint deduplicates atomically through `UNIQUE(canonical_user_key_hash, request_id)` plus INSERT and `23505` conflict handling. A duplicate returns the existing flag row id with `dedup=true`. (fact)

| Request field | Accepted values | Constraint |
|---|---|---|
| `feature_key` | `dinner_solve`, `substitution`, `cook_turn`, `recipe_import`, `pantry_parse`, `grocery_generate`, `cook_mode_realtime` | Must be one of the listed feature keys. (fact) |
| `request_id` | UUID-like ID or `voice:<session_id>:<turn_index>` | Stored as TEXT. (fact) |
| `flag_reason` | string | 1..500 chars. (fact) |
| `context_snapshot` | object | Serialized size ≤4 KiB. (fact) |

#### 3.2.1 Request example

```json
{
  "feature_key": "cook_turn",
  "request_id": "voice:7e8a2d8a-0bb4-4f7b-bb22-85491a39cdb7:12",
  "flag_reason": "The model told me to add raw flour at the end of cooking.",
  "context_snapshot": {
    "recipe_plan_id": "rp_20260424_family_chili",
    "step_index": 3
  }
}
```

#### 3.2.2 Success response

```json
{
  "ok": true,
  "flagged_output_id": "4cbaf0ba-45c1-46fe-9eb6-099a9873e1b0",
  "dedup": false
}
```

Duplicate response:

```json
{
  "ok": true,
  "flagged_output_id": "4cbaf0ba-45c1-46fe-9eb6-099a9873e1b0",
  "dedup": true
}
```

#### 3.2.3 Error surface

| Code | HTTP | Condition |
|---|---|---|
| `VAL-01` | 400 | Bad request body or field validation failure. (fact) |
| `AUTH-01` | 401 | Session JWT failure. (fact) |
| `METHOD-NOT-ALLOWED-01` | 405 | Non-POST request. (fact) |

## 4. Workflows

### 4.1 iOS user flagged-output ingestion [Phase 1 — built]

1. The iOS client sends `POST /v1/ops/flag-output` with `feature_key`, `request_id`, `flag_reason`, and optional `context_snapshot`. (fact)
2. The Edge Function validates the iOS session JWT through `verifySessionJWT`. (fact)
3. The handler hashes the canonical user key to a 16-character SHA-256 prefix. (fact)
4. The handler attempts owner-scoped lookups against `ai_request_log` and `ai_response_cache` using `canonical_user_key` and `request_id`. (fact)
5. The handler inserts the flag row with `flagged_by='user'`. (fact)
6. On `23505`, the handler selects the existing row and returns `dedup=true`. (fact)
7. The new or existing row appears in `flagged_outputs.list` when `state='open'`. (fact)

### 4.2 Admin-originated flagging [Phase 3 — deferred]

Admin-originated flags use `flagged_by='admin'`. (fact)

The backend shape accepts service-role inserts, but the admin console button has not shipped. (fact)

No Phase 1 SPA flow exists for admin-originated flag creation. (fact)

### 4.3 System-originated flagging [Phase 3 — deferred]

System-originated flags use `flagged_by='system'`. (fact)

The contract exists for hard-rule validator failures, but no current caller produces rows. (fact)

### 4.4 Flagged-output resolution [Phase 1 — built]

1. The admin opens a row in the SPA's Flagged Outputs page. (fact)
2. The dialog presents `dismissed`, `withdrawn`, and `canned_fallback_pinned`. (fact)
3. `dismissed` records resolution fields and performs no cache mutation. (fact)
4. `withdrawn` looks up raw `canonical_user_key` from `ai_request_log.request_id`, then deletes the `ai_response_cache` row filtered by both `canonical_user_key` and `request_id`. (fact)
5. `canned_fallback_pinned` looks up raw `canonical_user_key` from `ai_request_log.request_id`, then updates `ai_response_cache.response_body` with `canned_fallback_json`, filtered by both `canonical_user_key` and `request_id`. (fact)
6. If the `ai_request_log` row is missing for a cache-mutating resolution, the handler throws `VAL-01` 404 instead of performing an unscoped cache mutation. (fact)
7. If the cache mutation fails, the handler throws before updating `ops_flagged_outputs`; the admin sees the failure and retries. (fact)
8. After the cache mutation succeeds, the handler stamps resolution fields and writes audit. (fact)
9. Resolving an already-resolved row returns `VAL-01` 409. (fact)

### 4.5 Cost anomaly detection [Phase 1 — built]

1. `stir_ops_cost_anomaly_scan()` runs every 15 minutes through `stir-cost-anomaly-scan`. (fact)
2. The scan computes per-user daily spend aggregates over the last 24 hours from `ai_request_log`. (fact)
3. The scan compares aggregates against tier-derived thresholds. (fact)
4. Premium users above $3/day and Pro users above $8/day produce `daily_spend_2x`. (fact)
5. Any user above $10/day produces `daily_spend_hard_cap`. (fact)
6. A voice session with cumulative prompt tokens above 50000 produces `voice_session_tokens_over_cap`. (fact)
7. Per-type per-user deduplication uses a 24-hour `NOT EXISTS` window. (fact)
8. `runaway_session` is an enum value only; no detector emits it. (fact)

| Anomaly type | Phase | `details_json` shape |
|---|---|---|
| `daily_spend_2x` | `[Phase 1 — built]` | `{ tier, spend_24h_usd, call_count, top_features: [...] }`. (fact) |
| `daily_spend_hard_cap` | `[Phase 1 — built]` | `{ tier, spend_24h_usd, call_count, top_features: [...] }`. (fact) |
| `voice_session_tokens_over_cap` | `[Phase 1 — built]` | `{ session_id, cumulative_prompt_tokens, cumulative_response_tokens, turn_count }`. (fact) |
| `runaway_session` | `[Phase 3 — deferred]` | `{ session_id, span_minutes, turn_count }`; detector pending. (fact) |

The exact item schema for `top_features` is not specified. (fact)

### 4.6 Cost anomaly two-phase Sentry dispatch [Phase 1 — built]

1. `stir_ops_cost_anomaly_alert_dispatch()` runs every minute through `stir-cost-anomaly-alert-dispatch`. (fact)
2. The dispatch function selects up to 50 rows where `dispatched_at IS NULL`. (fact)
3. The dispatch function enqueues `pg_net` POSTs to Sentry's store endpoint. (fact)
4. The dispatch function captures the returned `pg_net` request handle. (fact)
5. The dispatch function batch-updates `dispatched_at=now()` and `sentry_request_id=<handle>` through `UNNEST`. (fact)
6. `stir_ops_cost_anomaly_alert_confirm()` runs every minute through `stir-cost-anomaly-alert-confirm`. (fact)
7. The confirm function reads `net._http_response` for rows with `dispatched_at IS NOT NULL`, `confirmed_at IS NULL`, and `sentry_request_id IS NOT NULL`. (fact)
8. HTTP 200..299 stamps `confirmed_at=now()`. (fact)
9. HTTP 4xx/5xx with `confirm_attempts < 5` clears dispatch state, increments `confirm_attempts`, and lets dispatch retry. (fact)
10. `confirm_attempts >= 5` stamps `confirmed_at=now()` and raises a Postgres warning. (fact)
11. Missing `net._http_response` after 5 minutes clears dispatch state for re-pickup. (fact)
12. The monitorable stuck-alert signal is `COUNT(*) FROM cost_anomalies WHERE dispatched_at IS NOT NULL AND confirmed_at IS NULL AND dispatched_at < now() - interval '15 min'`. (fact)
13. The Sentry DSN is read from `app_settings('SENTRY_DSN')` on each tick. (fact)
14. Malformed DSNs raise a warning with DSN length and a 20-character prefix only. (fact)

### 4.7 Backend force re-authentication [Phase 1 — built]

1. The admin sends `users.force_reauth` with a target `canonical_user_key`. (fact)
2. `stir_ops_force_reauth()` sets `reauth_required_at=now()` on the target row. (fact)
3. The RPC also sets `reauth_required_at=now()` on rows where `merged_into=<target>`. (fact)
4. The handler returns `reauth_required_at` and `merged_siblings_bumped`. (fact)
5. The handler attempts an audit row with action `users.force_reauth`. (fact)

### 4.8 iOS force-reauth enforcement [Phase 2 — contracted, iOS half pending]

`_shared/auth.ts::verifySessionJWT` performs a module-scope service-client lookup against `app_users` for every `/v1/*` handler that calls it. (fact)

The lookup selects `reauth_required_at` and `merged_into` by primary key on `canonical_user_key`. (fact)

If `reauth_required_at > iat`, using a `<=` boundary to reject same-second collisions, `verifySessionJWT` throws `AuthError('reauth_required')`. (fact)

If the user row has `merged_into`, the verifier performs one additional lookup on the target canonical user row for its `reauth_required_at`. (fact)

The universal gate adds about 1–3 ms per request for a single indexed lookup and at most one merged-chain hop. (fact)

Before commit `fd63bc1`, the gate was opt-in and no caller opted in. After `fd63bc1`, every `/v1/*` handler that calls `verifySessionJWT(req)` inherits the gate. (fact)

On `AUTH-01` with `reason=reauth_required`, iOS routes past silent retry to Sign in with Apple re-flow. Re-bootstrap alone is not sufficient for this reason because it mints a fresh JWT without identity rotation. (fact)

The iOS handling landed in `d6cea70`, but the iOS build had not shipped to TestFlight or App Store at spec-write time. (fact)

### 4.9 Quota reset [Phase 1 — built]

1. The admin sends `users.reset_quota` with a target `canonical_user_key` and feature key. (fact)
2. The action zeros `usage_counters.used_count` for the current period. (fact)
3. Supported feature keys are `dinner_solve`, `voice_cook_session`, and `recipe_import`. (fact)
4. The handler attempts an audit row with action `users.reset_quota`. (fact)

### 4.10 User status update [Phase 1 — built]

1. The admin sends `users.status` with a target `canonical_user_key` and status. (fact)
2. The API accepts `active` and `banned`. (fact)
3. The API rejects `merged` through Zod. (fact)
4. The handler attempts an audit row with action `users.status.updated`. (fact)

### 4.11 Prompt-version rollout [Phase 1 — built backend; Phase 3 — deferred UI]

1. The admin sends `prompt_versions.rollout` with `feature_key`, `version`, `rollout_pct`, and optional `is_default`. (fact)
2. The action updates `prompt_versions`. (fact)
3. If `is_default=true`, sibling versions have `is_default` cleared. (fact)
4. The handler attempts an audit row with action `prompt_versions.rollout`. (fact)
5. The SPA `/prompts` route is a DeferredPage stub. (fact)

### 4.12 Feature-flag update [Phase 1 — built backend; Phase 3 — deferred UI]

1. The admin sends `feature_flags.update` with `key` and at least one of `value`, `is_enabled`, or `rollout_pct`. (fact)
2. The action updates `feature_flags`. (fact)
3. If all optional fields are omitted, the action returns `{ noop: true, audit_id: null }`. (fact)
4. The handler attempts an audit row with action `feature_flags.updated` for non-noop updates. (fact)
5. The SPA `/flags` route is a DeferredPage stub. (fact)

### 4.13 Voice session listing [Phase 1 — built backend; Phase 3 — deferred UI]

`voice_sessions.list` returns voice sessions aggregated by `session_id`. (fact)

The current backend derives `session_id` with `split_part(request_id, ':', 2)` until the deferred rewrite uses the indexed `ai_request_log.session_id` column — see §13.4. (fact)

The Voice Sessions SPA route is a DeferredPage stub. (fact)

### 4.14 Audit-log read trail [Phase 1 — built backend; Phase 3 — deferred UI]

1. `users.detail` writes an audit row with `action='users.detail.viewed'`. (fact)
2. The read-audit row has `before_json=null` and `after_json=null`. (fact)
3. Targeted user-detail reads leave a trail. List reads do not. (fact)
4. `audit_log` SELECT RLS exists in Phase 1. (fact)
5. No `audit_log.list` action appears in the 11-action `/v1/ops/admin` router. (fact)
6. The SPA `/audit` route is a DeferredPage stub. (fact)
7. This spec treats audit-log table access as built and audit-log SPA inspection as deferred — see §Gaps. (uncertain)

## 5. Scheduled jobs

All jobs in this section are pg_cron-triggered unless explicitly stated otherwise. (fact)

Admins can inspect cron job metadata through `stir_ops_cron_job_info(p_name)`. The response shape for `stir_ops_cron_job_info` is not supplied — see §Gaps. (fact)

| Job | Phase | Schedule | Action | Failure behavior |
|---|---|---|---|---|
| `stir-cost-anomaly-scan` | `[Phase 1 — built]` | `*/15 * * * *` | Runs `stir_ops_cost_anomaly_scan()` to scan `ai_request_log` and insert anomalies. (fact) | Per-row failures appear in Postgres logs; next tick re-picks when dedup window allows. (fact) |
| `stir-cost-anomaly-alert-dispatch` | `[Phase 1 — built]` | `* * * * *` | Runs `stir_ops_cost_anomaly_alert_dispatch()` to enqueue Sentry POSTs through `pg_net`. (fact) | Stuck dispatches surface through phase-2 retry or dead-letter. (fact) |
| `stir-cost-anomaly-alert-confirm` | `[Phase 1 — built]` | `* * * * *` | Runs `stir_ops_cost_anomaly_alert_confirm()` to read `net._http_response` and stamp confirmation. (fact) | Per-row retry cap is 5 attempts, then `RAISE WARNING`. (fact) |
| `stir-reactivation-scan` | `[Phase 1 — built]` | `0 18 * * *` | Runs `stir_ops_reactivation_enqueue()` to enqueue reactivation push notifications. (fact) | Advisory lock prevents concurrent double-enqueue. (fact) |
| `stir-audit-log-retention` | `[Phase 1 — built]` | `30 9 * * *` | Trims `audit_log` rows older than 90 days. (fact) | Standard pg_cron failure path. (fact) |
| `stir-webhook-log-retention` | `[Phase 1 — built, pre-step-8]` | Existing schedule not supplied. (fact) | Trims `webhook_log`. (fact) | Not supplied. (fact) |
| `stir-ai-response-cache-retention` | `[Phase 1 — built, pre-step-8]` | Existing schedule not supplied. (fact) | Trims `ai_response_cache`. (fact) | Not supplied. (fact) |
| `stir-pgmq-dispatch` invoking `pgmq-dispatch` | `[Phase 1 — built]` | every 30 seconds | Invokes the `pgmq-dispatch` Edge Function to process `notification_jobs`. (fact) | Hardened in commit `66a6351` with a two-part reclaim sweep and `push_send` Zod validation. (fact) |

`pgmq-dispatch` is an Edge Function rather than a SQL pg_cron job. The `stir-pgmq-dispatch` pg_cron trigger invokes the Edge Function every 30 seconds. (fact)

## 6. Ops SPA

### 6.1 Stack [Phase 1 — built]

The SPA uses Vite, React 18, TypeScript 5, Tailwind 3.4, and `@supabase/supabase-js`. (fact)

Local development runs with `npm run dev` on `localhost:5173`. (fact)

The production build command is `tsc -b && vite build`, producing `ops/dist/`. (fact)

The SPA has no runtime test harness in Phase 1 — no Vitest, React Testing Library, or Playwright. Accepted test debt is tracked in §13.11. (fact)

Directory structure is `ops/src/` with `main.tsx`, `App.tsx`, `index.css`, `components/{AppShell.tsx, ConfirmDialog.tsx}`, `hooks/useAdminSession.ts`, `lib/{supabase.ts, api.ts}`, and pages for login, dashboard, users, flagged outputs, and cost anomalies. (fact)

### 6.2 LoginPage [Phase 1 — built]

`LoginPage` presents a Supabase magic-link email input. (fact)

On magic-link return, `useAdminSession` verifies the Supabase session and probes `ops_admins` through the `ops_admins_self_select` RLS policy. (fact)

A non-admin sees a not-authorized page. An admin enters `AppShell`. (fact)

### 6.3 DashboardPage [Phase 1 — built]

`DashboardPage` renders three KPI cards: active users, open flagged outputs, and open cost anomalies. (fact)

The page uses `Promise.allSettled` and a per-card `CardState` union with loading, loaded, and error states. One slow card does not block the full dashboard. (fact)

Flag severity thresholds are warn at 5 and critical at 25. (fact)

Anomaly severity thresholds are warn at 1 and critical at 10. (fact)

### 6.4 UsersPage [Phase 1 — built]

`UsersPage` supports search by canonical user key, RevenueCat id, or install id. (fact)

The page includes a tier filter. (fact)

The table shows canonical user key, tier, billing, status, 30-day cost, flags, last seen, and actions. Billing, 30-day cost, and last-seen columns are hidden below the `md` breakpoint. (fact)

Actions include force reauth, reset quota, ban, and unban. (fact)

| Action | Confirmation |
|---|---|
| Force reauth | Typed confirmation requiring `REAUTH`. (fact) |
| Ban | Typed confirmation requiring `BAN`. (fact) |
| Unban | Typed confirmation requiring `UNBAN`. (fact) |
| Reset quota | Enum-select confirmation for `feature_key`. (fact) |

The ban button is visually destructive at rest with red text and red border. (fact)

### 6.5 FlaggedOutputsPage [Phase 1 — built]

`FlaggedOutputsPage` filters by open, resolved, or all state. (fact)

Rows render `feature_key`, `flagged_by`, `flag_reason`, and raw output JSON. Raw output JSON is collapsible through `<details>`. (fact)

Resolve actions include dismissed, withdrawn, and canned fallback pinned. The canned fallback action uses a JSON textarea dialog. (fact)

The page includes loading state and `<article>` ARIA landmarks. (fact)

### 6.6 CostAnomaliesPage [Phase 1 — built; status sub-field bug pending fix]

`CostAnomaliesPage` has severity filter tabs for all, warn, and critical. (fact)

The page renders anomaly type, severity, and prettified `details_json`. (fact)

The page references two timestamp fields: `detected_at` (header, works correctly) and `alerted_at` (status sub-field, stale). Migration `20260424000004` added `dispatched_at` and `confirmed_at` columns and backfilled legacy `alerted_at` values into them, but it did NOT drop `alerted_at` and the post-migration write path does not stamp it on new rows. The status sub-field therefore renders "alert pending" indefinitely on rows detected after the migration, even after Sentry delivery confirmed. Verified by CC audit 2026-04-24. (fact)

Fix path: replace the `alerted_at` predicate with a 3-state predicate on `(confirmed_at, dispatched_at)`: "confirmed <time>" | "dispatched <time>, awaiting Sentry confirm" | "alert pending". `alerted_at` is dead-for-new-rows. Tracked as SPA build step 1 — see §Gaps. (fact)

### 6.7 Voice Sessions page [Phase 3 — deferred]

The `/voice` route renders a DeferredPage stub. (fact)

The backend `voice_sessions.list` action exists in Phase 1. (fact)

### 6.8 Feature Flags page [Phase 3 — deferred]

The `/flags` route renders a DeferredPage stub. (fact)

The backend `feature_flags.update` action exists in Phase 1. (fact)

### 6.9 Prompt Versions page [Phase 3 — deferred]

The `/prompts` route renders a DeferredPage stub. (fact)

The backend `prompt_versions.rollout` action exists in Phase 1. (fact)

### 6.10 Audit Log page [Phase 3 — deferred]

The `/audit` route renders a DeferredPage stub. (fact)

`audit_log` SELECT RLS exists in Phase 1. (fact)

No `audit_log.list` action is specified in the admin router inventory — see §Gaps. (fact)

### 6.11 DeferredPage [Phase 1 — built]

DeferredPage hides the "Backend call: ..." developer hint in production. The hint is gated on `import.meta.env.DEV`. (fact)

### 6.12 ConfirmDialog [Phase 1 — built]

`ConfirmDialog.tsx` exports `useConfirm()` and a dialog component. (fact)

Dialog modes are `plain`, `typed`, `enum_select`, and `json`. (fact)

The JSON mode uses an inline textarea with `JSON.parse` validation rather than a separate editor component. (fact)

The dialog implements focus trap, Escape-to-cancel, and ARIA roles. (fact)

### 6.13 AppShell [Phase 1 — built]

`AppShell.tsx` provides a responsive sidebar using `md:w-56`, `w-full`, and `md:h-screen`. (fact)

Below the `md` breakpoint, the shell uses a hamburger toggle. (fact)

`aria-expanded` and `aria-controls` are wired for keyboard navigation. (fact)

### 6.14 API client [Phase 1 — built]

`api.ts::callAdmin<T>(action, params)` is the SPA fetch wrapper. (fact)

The wrapper attaches `x-request-id: crypto.randomUUID()` per call. (fact)

On a 401 response, it calls `supabase.auth.refreshSession()` once. If refresh produces a new session, it retries the original request once. (fact)

Still-failing responses propagate as `AdminApiError(code, status, reason?, message?)`. (fact)

There is no silent retry loop and no bespoke `AUTH_REFRESH_FAILED` code. (fact)

### 6.15 Design posture [Phase 1 — built]

The ops SPA does not follow Stir's mobile-first product design system; this is an explicit decision, not an oversight. The SPA is desktop-first and internal. (fact)

The palette uses Tailwind neutral-950, 900, 800, 700, 400, 300, amber-500 primary, and red-400/900 destructive. (fact)

Focus rings are applied through `@layer base` on interactive elements. (fact)

There is no Dynamic Type handling, no Reduce Motion handling, and no iOS accessibility convention layer. (fact)

Responsive support uses the `md` breakpoint only. Below `md`, the shell shows hamburger navigation and hides low-priority table columns. Desktop is the primary target; mobile is a convenience target. (fact)

### 6.16 SPA deployment [Phase 1 — dev-only; Phase 3 — deferred hosted]

Current Phase 1 operation runs `npm run dev` locally against the prod Supabase URL. (fact)

The magic-link session persists in localStorage. (fact)

There is no hosted ops URL in Phase 1. (fact)

ADR 0024 defines the Step 9 deployment plan: `ops-ui` Edge Function serves `index.html`; `GET /assets/*` routes to a public `ops-spa` Supabase Storage bucket. (fact)

The deploy flow is `npm run build`, Supabase Storage upload, and `supabase functions deploy ops-ui`. The planned hosted deployment is single-origin with Supabase Auth. (fact)

The bundle size is about 285 KiB and about 86 KiB gzipped. (fact)

## 7. Admin role model

### 7.1 Single-role admin model [Phase 1 — built]

All `ops_admins` rows grant full access in Phase 1. There is no role differentiation. (fact)

Daniel is the current single admin. The row was seeded through the SQL editor. (fact)

Admin provisioning is manual through SQL editor `INSERT` after confirming a Supabase Auth magic-link sign-in works. The runbook is `docs/runbooks/ops-admin-provisioning.md`. (fact)

### 7.2 Admin revocation [Phase 1 — built]

Revocation is `DELETE FROM ops_admins WHERE auth_user_id=<uuid>` through the SQL editor. (fact)

After revoking an admin row, the runbook also calls for `users.force_reauth` on the admin's canonical user key if they have one. (fact)

Admin auth itself does not route through `canonical_user_key`; the force-reauth revocation step covers the hypothetical case where an admin is also an iOS user. (fact)

### 7.3 Role differentiation [Phase 3 — deferred]

Read-only, support, and full-admin tiers are deferred. (fact)

The trigger is admin count growing past about five. (fact)

## 8. Error codes

Ops Admin reuses Stir's global error-code namespace from Stir full spec §6. No new `OPS-*` codes are introduced. (fact)

| Code | HTTP | Meaning in ops-admin context |
|---|---|---|
| `AUTH-01` | 401 | JWT failure; `reason` discriminates `missing`, `expired`, `malformed`, `signature_invalid`, `user_stale`, `reauth_required`, `wrong_issuer`. (fact) |
| `VAL-01` | 400 | Zod validation failure. (fact) |
| `VAL-01` | 404 | User, flagged output, feature flag, or prompt version not found. (fact) |
| `VAL-01` | 409 | Flagged output already resolved. (fact) |
| `BILL-01` | 403 | JWT valid but caller has no `ops_admins` row. (fact) |
| `RATE-01` | 429 | `ip:ops_admin_hourly` exhausted. (fact) |
| `NET-01` | 500 | Unknown error with sanitized message and raw error logged. (fact) |
| `METHOD-NOT-ALLOWED-01` | 405 | Non-POST to `/v1/ops/admin` or `/v1/ops/flag-output`. (fact) |

The wire error envelope is `{ error: "<CODE>", message: "<str>", reason?: "<str>", field_errors?: [{ field, issue }] }`. (fact)

## 9. Telemetry

The 8 `ops_admin.*` events listed below emit from `Backend/supabase/functions/ops-admin/index.ts` as of commit `8635c61` (Phase C of the telemetry wiring bundle, 2026-04-24). Property additions in commit `35e077a` (Phase C amendment). (fact)

Telemetry uses PostHog event names prefixed with `ops_admin.*`. Telemetry properties use `actor_id`, not `actor_email`, to avoid email PII. (fact)

Every `ops_admin.*` event includes two mandatory properties beyond the per-event list below:

- `request_id` (TEXT — Edge Function `x-request-id` value) — cross-system join key per `docs/telemetry/canonical-properties.md` §7.
- `actor_id` (string — Supabase Auth user UUID for human admins; reserved `system:<source>` form for non-human actors per canonical-properties.md §3) — source of truth for action attribution.

Raw `canonical_user_key` values are hashed with SHA-256 truncated to 16 hex characters before telemetry emission. The canonical property name is `canonical_user_key_hash` (per ADR 0027). (fact)

PostHog retention uses the PostHog default and is not subject to the `audit_log` 90-day trim. `audit_log` is the authoritative record for admin actions; PostHog is for aggregate dashboards and cross-system joins. (fact)

| Event | Phase | Per-event properties |
|---|---|---|
| `ops_admin.users.list_queried` | `[Phase 1 — built]` | `{ tier_filter, has_search, limit, offset, result_count }`. (fact) |
| `ops_admin.users.detail_viewed` | `[Phase 1 — built]` | `{ canonical_user_key_hash, audit_id }`. (fact) |
| `ops_admin.users.quota_reset` | `[Phase 1 — built]` | `{ canonical_user_key_hash, feature_key, noop, audit_id }`. (fact) |
| `ops_admin.users.status_changed` | `[Phase 1 — built]` | `{ canonical_user_key_hash, from_status, to_status, audit_id }`. (fact) |
| `ops_admin.users.force_reauth` | `[Phase 1 — built]` | `{ canonical_user_key_hash, merged_siblings_bumped, audit_id }`. (fact) |
| `ops_admin.flagged_outputs.resolved` | `[Phase 1 — built]` | `{ feature_key, resolution_action, target_id, audit_id }`. (fact) |
| `ops_admin.prompt_versions.rollout` | `[Phase 1 — built]` | `{ feature_key, version, rollout_pct, is_default, target_id, audit_id }`. (fact) |
| `ops_admin.feature_flags.updated` | `[Phase 1 — built]` | `{ flag_key, target_id, is_enabled, rollout_pct, noop, audit_id }`. (fact) |

Per-event property notes:

- `users.list_queried.has_search` — boolean indicating whether `params.search` was set; renamed from spec-original `search_present`. (fact)
- `users.list_queried.result_count` — page-size of returned rows (not filtered-across-pages total). Per Phase C amendment `35e077a`. (fact)
- `users.detail_viewed.audit_id` (and similar `audit_id` properties on all mutating events) — the `audit_log.id` of the row written by the same handler. Lets dashboards join PostHog event → audit_log row for full-context drilldown. (fact)
- `users.quota_reset.noop` and `feature_flags.updated.noop` — boolean indicating the request had no mutating effect (early-return branch). Distinguishes meaningful actions from no-op admin calls. (fact)
- `users.status_changed.from_status` — prior status read from the RPC's `before` snapshot. Per Phase C amendment `35e077a`. (fact)
- `users.force_reauth.merged_siblings_bumped` — fan-out count of merged sibling rows updated by the cascade; returned by `stir_ops_force_reauth` RPC. Per Phase C amendment `35e077a`. (fact)
- `flagged_outputs.resolved.feature_key` — pulled from the flagged row's `feature_key`, NOT from `params.action` (which is the resolution enum). (fact)
- `flagged_outputs.resolved.target_id` — the flagged-output UUID. Safe to emit (UUID, not user identity). (fact)
- `prompt_versions.rollout.target_id` — composite key `<feature_key>:<version>`. (fact)
- `feature_flags.updated.flag_key` and `target_id` — both are the flag key string (renamed from spec-original `key` for cross-event clarity). (fact)
- `feature_flags.updated.is_enabled` and `rollout_pct` — present only when the corresponding params field was set; `null` when unchanged. (fact)

Telemetry conformance: every PostHog event and Sentry capture in Stir conforms to the canonical property schema documented at `docs/telemetry/canonical-properties.md` (decision: ADR 0027). New events and alerts must follow the canonical-schema reviewer checklist in `docs/runbooks/telemetry-canonical-schema.md`.

## 10. Security posture

### 10.1 Admin credential compromise [Phase 1 — built mitigations; Phase 3 — deferred per-admin bucket]

The credential-compromise threat is an attacker obtaining an admin magic link or session token. (fact)

Mitigations include IP rate limit `ip:ops_admin_hourly`, Supabase Auth session TTL, JWT secret rotation runbook, force-reauth as an operational kill switch, and admin revocation through deleting the `ops_admins` row. (fact)

Supabase Auth session lifetime is the default: 1-hour access token and 60-day refresh token. (fact)

Per-admin rate limiting is not implemented and is Phase 3 deferred — triggers when admin count exceeds five or global IP caps become noisy. (fact)

### 10.2 Cross-path JWT confusion [Phase 1 — built]

The cross-path JWT-confusion threat is an iOS session JWT presented to an admin endpoint. (fact)

`verifyAdminAuth` rejects iOS session JWTs before the `ops_admins` lookup with a triple gate plus admin lookup:

1. `iss` must not be `stir-backend`. (fact)
2. `iss` must end with `/auth/v1`. (fact)
3. `sub` must be UUID-shaped. (fact)
4. The auth user must have an `ops_admins` row. (fact)

iOS session JWTs have `iss='stir-backend'` and a non-UUID `sub`, so they are rejected at the admin boundary. (fact)

### 10.3 SPA XSS [Phase 1 — built mitigations; Phase 3 — deferred CSP]

React escaping is the primary Phase 1 XSS mitigation. (fact)

Admin-facing JSON rendering uses `<pre>{JSON.stringify(...)}</pre>` interpolation. The SPA does not use `dangerouslySetInnerHTML`, eval, or direct DOM manipulation. (fact)

Content Security Policy is not set in Phase 1. CSP is Phase 3 deferred as defense-in-depth. (fact)

### 10.4 Replay attack [Phase 1 — built posture]

JWTs carry `exp` through Supabase Auth session TTL. Supabase Auth refresh tokens rotate. (fact)

There is no per-request nonce. The supplied material treats this as acceptable for the admin surface. (fact)

### 10.5 Privilege escalation [Phase 1 — built posture]

There is no admin role hierarchy in Phase 1. (fact)

An admin cannot create another admin through the ops SPA because there is no admin-creation endpoint. (fact)

Granting admin requires inserting into `ops_admins`, which requires Supabase-project-level SQL editor access. Supabase-project-level auth is separate from the admin magic-link surface. (fact)

### 10.6 Cross-user cache corruption [Phase 1 — built mitigation]

`flagged_outputs.resolve` scopes cache mutations by `ai_request_log.canonical_user_key` and `request_id`. (fact)

If `ai_request_log` cannot resolve the owner for a cache-mutating resolution, the handler returns `VAL-01` 404. (fact)

This prevents cross-user cache damage when request ids collide or are leaked. The cache-scoping fix is identified as C2 in commit `e3b3008`. (fact)

### 10.7 IP allowlisting [Phase 3 — deferred]

There is no IP allowlisting currently. (fact)

The supplied priority is low while admin population is single-digit and rate-limited. (fact)

### 10.8 JWT secret rotation [Phase 1 — built runbook]

`STIR_JWT_SECRET` is the dual-surface signer for iOS session JWT verification and admin Supabase Auth JWT verification. (fact)

The runbook is `docs/runbooks/jwt-secret-rotation.md`. (fact)

During rotation, the expected iOS UX is silent re-bootstrap on `AUTH-01 reason=signature_invalid`. (fact)

Sentry spikes during rotation because iOS logs `signature_invalid` at error severity and captures to Sentry. Alerts on `auth_reason=signature_invalid` should be silenced during the rotation window. (fact)

## 11. Deployment + ops

### 11.1 Current deployment state [Phase 1 — built, not prod-deployed]

The step-8 review bundle landed on origin/main but is not yet deployed to the prod Supabase project at spec-write time. (fact)

The backend deploy sequence for this bundle is iOS-first or simultaneous. The reason is that the universal reauth gate in commit `fd63bc1` rejects pre-bump iOS JWTs, and iOS must already handle `reason=reauth_required` through `d6cea70`. (fact)

### 11.2 SPA hosting [Phase 1 — dev-only; Phase 3 — deferred hosted]

Current SPA operation is local Vite dev server on `localhost:5173`. The admin points the local SPA at the prod Supabase URL. (fact)

The hosted plan is the ADR 0024 Edge Function plus Storage deployment. (fact)

### 11.3 Environment separation [Phase 1 — built posture; Phase 3 — deferred separation]

There is one `ops_admins` table in the prod Supabase project. There is no staging admin surface. Per-environment admin separation is Phase 3 deferred. (fact)

### 11.4 Access [Phase 1 — built]

Daniel is the current sole admin. The row was seeded through the SQL editor. (fact)

### 11.5 Incident response [Phase 1 — built posture]

Backend incidents follow Stir full spec §13 Alerts and the Sentry alert chain. Ops Admin is the investigation tool, not the incident-paging mechanism. (fact)

For SPA outages, the supplied fallback is `cd ops && npm run dev` locally. (fact)

If the issue persists locally against prod Supabase, the failure is in the build, auth, or prod Supabase backend path. (inference)

### 11.6 Rollback [Phase 1 — built posture; Phase 3 — hosted SPA rollback]

Edge Function rollback is redeploying the function from a previous commit checkout. (fact)

Phase 3 SPA rollback is redeploying the previous Vite bundle. (fact)

Migrations are forward-only by project convention. Rollback for schema changes uses a compensating migration, not a reverse migration. (fact)

### 11.7 Step-8 commit context [Phase 1 — built]

The step-8 review bundle closed Phase 1 scope in 11 commits on origin/main:

```text
baf9582  feat(ops): schema — request_id text consolidation
f14ade6  feat(ops): schema — session_id + performance indexes
be971c4  feat(ops): schema — two-phase dispatch + input caps
e3b3008  fix(ops-admin): polish — validation + cache scoping + audit + rate limit
819ee34  fix(apns): hardening — classification + timeout + mint coalescing + PKCS#8
fd63bc1  fix(auth): reauth client module-scope + iat edge case
66a6351  fix(pgmq): reliability — two-part reclaim sweep + push_send Zod
d3c82e5  feat(ops-spa): confirm dialogs + destructive-action pages
ab47d68  feat(ops-spa): shell + global styles + data-fetch hardening
cde2bd5  chore(ops): iOS polish + JWT runbook + §Deferred batch
8161b85  docs(claude): reconcile §Deferred — stir_ops_list_voice_sessions observation
```

Earlier step-8 phase commits include `80c2ccc`, `42d2fd5`, `d6cea70`, `c0332d9`, `bf6f318`, `123f278`. (fact)

| Commit | Coverage |
|---|---|
| `80c2ccc` | Phase 2 ops-admin router and ops-flag-output. (fact) |
| `42d2fd5` | Phase 1 foundation. (fact) |
| `d6cea70` | iOS reauth handling, `FlagOutputService`, `FlagOutputSheet`. (fact) |
| `c0332d9` | Phases 4 through 6. (fact) |
| `bf6f318` | Phase 8 ops SPA. (fact) |
| `123f278` | Phase 9 ADRs and runbooks. (fact) |

## 12. ADR cross-references

### 12.1 ADR 0023 — Admin auth via Supabase Auth + ops_admins link table [Phase 1 — built]

ADR 0023 is accepted. (fact)

Decisions:
- Supabase Auth magic-link admin authentication rather than iOS Sign in with Apple reuse. (fact)
- `ops_admins` as the presence-based admin role gate. (fact)
- `is_admin()` as a fail-closed `SECURITY DEFINER` function with `RAISE WARNING` on exceptions. (fact)
- `verifyAdminAuth` triple-gating at the Edge Function boundary. (fact)

Rejected alternatives: reusing iOS session JWT machinery, Google Workspace OAuth, email-domain gating, separate Supabase project. (fact)

### 12.2 ADR 0024 — Ops SPA local in step 8, Edge Function + Storage in step 9 [Phase 1 — built local; Phase 3 — deferred hosted]

ADR 0024 is accepted for step 8 and deferred for step 9 deployment. (fact)

Decisions:
- Vite dev server local-only operation for solo-admin demo use in step 8. (fact)
- `ops-ui` Edge Function plus `ops-spa` Supabase Storage bucket for step 9. (fact)
- Single-origin with Supabase Auth, avoiding CORS. (fact)

Rejected alternatives: Vercel/Netlify, bundle-inline-in-Edge-Function, S3/CloudFront. (fact)

Revisit trigger: admin count above five or ops SPA iteration rate above one deploy per week. (fact)

### 12.3 ADR 0025 — Eval harness structure [Out of ops-admin scope]

ADR 0025 is out of ops-admin scope. (fact)

ADR 0025 defines eval structure under `Backend/evals/`. (fact)

### 12.4 ADR 0026 — Reactivation push schedule [Phase 1 — built]

ADR 0026 is accepted. (fact)

Decisions:
- Daily 18:00 UTC `stir-reactivation-scan` cron. (fact)
- Plus-or-minus one hour DST ambiguity is acceptable because reactivation is a daily nudge rather than a punctual event. (fact)

## 13. Open questions + §Deferred

### 13.1 W16 processPushSend integration coverage [Phase 3 — deferred]

The scaffolded coverage was reverted because assertions were silently skipped. (fact)

Real coverage requires a mock APNs HTTP/2 server and a reachability seam through dependency injection at fetch. (fact)

Trigger: step-9 APNs compliance-test infrastructure. Owner: step 9. (fact)

### 13.2 Per-admin rate-limit bucket [Phase 3 — deferred]

The global `ip:ops_admin_hourly` bucket is built. A per-admin bucket keyed on `admin.authUserId` is deferred for account-compromise defense. (fact)

Trigger: admin count above five or call volume making the global cap noisy. Owner: step 9. (fact)

### 13.3 SupabaseSessionClient HTTPErrorHandler.map refactor [Phase 3 — deferred]

iOS `perform`, `performNoContent`, and `performStream` each have about 100 LOC of duplicated error mapping. A shared helper is deferred. (fact)

Trigger: a new `AUTH-01` reason or a fourth perform variant. Owner: step 9. (fact)

### 13.4 Cost anomaly session_id rewrite and runaway_session detector [Phase 3 — deferred]

`stir_ops_cost_anomaly_scan()` still uses `split_part(request_id, ':', 2)` instead of the indexed `session_id` column. The `runaway_session` enum exists, but no detector emits it. The rewrite and detector are bundled together. (fact)

Trigger: 7+ days after backfill stabilizes. Owner: step 9 before beta scale ramp. (fact)

### 13.5 Per-feature canned_fallback_json schema registry [Phase 3 — deferred]

Current Zod accepts any object up to 64 KiB. Per-feature validation requires a schema registry discriminated by `feature_key`. (fact)

Trigger: step 9 before beta opens the console to non-Daniel admins. (fact)

### 13.6 APNs untested changes W10/W11/W44 [Phase 3 — deferred]

Timeout, mint coalescing, and PKCS#8 parse-error hardening lack direct tests. (fact)

The required infrastructure is shared with the mock-APNs work in §13.1. (fact)

Trigger: step-9 APNs compliance-test infrastructure. (fact)

### 13.7 pgmq-dispatch reclaim sweep as SQL stored proc [Phase 3 — deferred]

The current TypeScript reclaim sweep is edge-runtime-dependent for tests. The deferred extraction target is `stir_pgmq_reclaim_sweep()`. Tests then call `svc.rpc()` directly. (fact)

Trigger: next sweep-logic change or recurrence of Path A contamination. Owner: step 9. (fact)

### 13.8 Zod and CHECK synchronization invariant [Phase 3 — deferred trigger discipline]

Size caps on `ops_flagged_outputs` are enforced in both Zod and SQL CHECK constraints. Manual discipline keeps both layers synchronized. (fact)

Trigger: any change to `CONTEXT_SNAPSHOT_MAX_BYTES`, `CANNED_FALLBACK_MAX_BYTES`, or the `flag_reason` cap. Owner: as triggered. (fact)

### 13.9 Isolated-worktree verification Docker-mount limitation [Phase 3 — deferred trigger discipline]

The Edge runtime container mounts from the main tree rather than the verify worktree. The Path A hybrid protocol is documented. (fact)

Trigger: a bundle with at least 3 commits and a Path A skip list above 30% of tests. Owner: as triggered. (fact)

### 13.10 TanStack Query migration for ops SPA [Phase 3 — deferred]

All four built pages use `useEffect` fetch with eslint-disable. This is accepted technical debt against the global "never use useEffect" rule. The migration target is TanStack Query. (fact)

Trigger: SPA growth beyond 4 pages or step-9 polish. Owner: step 9. (fact)

### 13.11 Ops SPA runtime test harness [Phase 3 — deferred]

There is no Vitest, React Testing Library, or Playwright harness in Phase 1. Current validation is build-only through `tsc -b` and `vite build`. (fact)

The v1 minimum is Vitest, React Testing Library, one smoke test per page, and one e2e for `users.list → detail → force_reauth`. (fact)

Trigger: SPA growth beyond 6 pages or a user-reported regression uncaught by build. Owner: step 9. (fact)

### 13.12 stir_ops_list_voice_sessions flake [Phase 3 — deferred]

The flake was red in isolation before the bundle and observed passing at bundle close. The cause is unattributed. (fact)

Owner: revisit if recurrence is observed. (fact)

## §Gaps

| # | Gap | Section | Missing fact |
|---|---|---|---|
| 1 | Notification job write posture inconsistent. | §2.12 | Overview lists `notification_jobs` enqueue as an admin write surface, but no `/v1/ops/admin` action, RPC name, SPA control, request schema, or audit action for enqueue is supplied. |
| 2 | Cost anomaly resolution mechanism unspecified. | §2.5, §3.1 | `cost_anomalies` has `resolved_at` and `resolved_by`, and detector dedup semantics reference admin resolution opening fresh alerts, but no `cost_anomalies.resolve` endpoint, RPC, SPA control, request schema, audit action, or workflow is supplied. |
| 3 | Cost anomalies page status sub-field stale. | §6.6 | Verified by CC audit 2026-04-24: page renders `detected_at` (correct) AND `alerted_at` (stale). Migration `20260424000004` did NOT drop `alerted_at`; no post-migration write path stamps it. Status sub-field shows "alert pending" indefinitely on new rows. Fix is local to `ops/src/pages/CostAnomaliesPage.tsx`: 3-state predicate on `(confirmed_at, dispatched_at)`. Tracked as SPA build step 1. |
| 4 | Audit log inspection posture inconsistent. | §4.14, §6.10 | `audit_log_admin_select` RLS exists but `/audit` is a DeferredPage stub and the API inventory lists no `audit_log.list` action. Treated as: table access built, SPA inspection deferred. |
| 5 | Exact audit action strings for flagged-output resolution not enumerated. | §3.1 | Examples like `flagged_outputs.resolved.withdrawn` and telemetry action `ops_admin.flagged_outputs.resolved` are given, but exact audit action strings for all three resolution actions are not enumerated. Resolved by Phase C audit: confirmed three forms `flagged_outputs.resolved.{dismissed,withdrawn,canned_fallback_pinned}` at `ops-admin/index.ts::handleFlaggedOutputsResolve`. |
| 6 | Full schemas for non-core operational tables not provided. | §2.6–§2.16 | `app_users`, `entitlement_snapshots`, `usage_counters`, `ai_request_log`, `ai_response_cache`, `voice_session_owners`, `notification_jobs`, `device_installations`, `feature_flags`, `prompt_versions`, `webhook_log` lack full column inventory, types, nullability, constraints, indexes, RLS policy names, and retention details. |
| 7 | `stir_ops_cron_job_info(p_name)` response shape unspecified. | §5 | Admins can inspect scheduled jobs through the RPC, but return columns and error behavior are not defined. |
| 8 | `top_features` item schema unspecified. | §4.5 | Cost anomaly details include `top_features: [...]`, but the item shape is not provided. |
| 9 | Raw AI snapshot schemas unspecified. | §2.3, §3.2 | `raw_input_json`, `raw_output_json`, and `context_snapshot_json` are described by storage limits and source, but not by feature-specific schemas. |
| 10 | Per-feature `canned_fallback_json` schemas unspecified. | §2.3, §4.4, §13.5 | Current validation accepts any 64 KiB object; per-feature schema registry is deferred. |
| 11 | Exact success payloads for several admin actions not fully specified. | §3.1 | Detailed response fields exist for `users.force_reauth` and high-level returns for other actions, but not exact JSON envelopes for every action. The full shapes of `users.detail`, `users.list`, `flagged_outputs.list`, `cost_anomalies.list`, and `voice_sessions.list` responses are not supplied. |
| 12 | Sentry store endpoint request body shape unspecified. | §4.6 | The dispatch enqueues POSTs to Sentry's store endpoint, but the request body shape is not provided. |
| 13 | Service-role Edge Function path for `ops_admins` lifecycle unspecified. | §2.1, §7.1 | Mentioned as an option, but no endpoint, function name, request schema, or runbook step is supplied beyond SQL editor provisioning. |
| 14 | Source-table RLS posture not supplied for non-ops-owned read surfaces. | §2.6–§2.16 | `app_users`, `entitlement_snapshots`, `ai_request_log`, `voice_session_owners`, `device_installations`, and others lack supplied RLS policy names. |
| 15 | Supabase Auth token TTL override status unspecified. | §10.1 | Defaults are supplied (1-hour access, 60-day refresh), but no project-level override status is supplied beyond "no per-admin override." |
| 16 | Runbook step-by-step contents not provided. | §7.1, §10.8, §11 | `docs/runbooks/ops-admin-provisioning.md` and `docs/runbooks/jwt-secret-rotation.md` are named but their step-by-step contents are not in the spec. |
| 17 | Design-system section cross-reference unresolved. | §6.15 | Stir's mobile product design system is named but no section number is provided in source material, so cross-reference is by name only. |

## Appendix A — Source spec lineage

| Element | Source |
|---|---|
| §1 Overview structure with phase-marker table | Spec A |
| §2 Entity catalog split (core ops vs read/write source) | Spec A |
| §2 Enum value sub-tables (`ops_flag_source`, `cost_anomaly_type`, `app_users.status`, `billing_state`, reset feature keys) | Spec A |
| §3.1 11-action JSON request examples | Spec A |
| §3.1 Per-error-code JSON examples | Spec A |
| §3.1 `_shared/rate_limiter.ts` location | Spec A |
| §4 Workflow split: backend reauth (§4.7) and iOS enforcement (§4.8) as separate items | Spec B |
| §4 Voice session listing (§4.13) as standalone workflow | Spec B |
| §4 Quota reset (§4.9) and User status update (§4.10) as standalone workflows | Spec A |
| §6 Granular component sections (DeferredPage, ConfirmDialog, AppShell, API client as 6.11–6.14) | Spec B |
| §6.6 Cost anomalies UI timestamp ambiguity flagged | Spec B |
| §7 Three named sub-sections for admin role model | Spec A |
| §10.6 "C2 in commit `e3b3008`" cache-scoping fix attribution | Spec A |
| §11.7 Per-commit phase-mapping table | Spec A |
| (uncertain) tag on cost anomalies UI label, audit log SPA route | Spec B |
| (inference) tag for derivation chains | Spec B |
| §Gaps as table format | Spec B |
| §Gaps content (combined 18-item set) | Both |
