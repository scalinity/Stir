# Spec sync patch — Ops Admin Specification (Obsidian vault)

**Target:** `Stir/Stir Specs/Stir - Ops Admin Specification.md`
(Obsidian vault — outside repo working dir).

**Source of truth:** This patch reflects decisions captured in the
repo at:

- `docs/decisions/0027-telemetry-canonical-property-schema.md`
- `docs/telemetry/canonical-properties.md`
- `docs/telemetry/2026-04-24-audit.md`

**Application:** Apply each edit manually in the Obsidian vault.
None of these are mechanical sed replacements — each may require
prose adjustment to the surrounding paragraph.

---

## §9 — Retag 8 ops_admin.* events from "proposed" to "built"

The 8 `ops_admin.*` events listed in spec §9 emit from
`Backend/supabase/functions/ops-admin/index.ts` as of commit
`8635c61` (telemetry wiring bundle, 2026-04-24). Update the section
header from `[Phase 1 — proposed surface]` to `[Phase 1 — built]`
on each:

- `ops_admin.users.list_queried`
- `ops_admin.users.detail_viewed`
- `ops_admin.users.quota_reset`
- `ops_admin.users.status_changed`
- `ops_admin.users.force_reauth`
- `ops_admin.flagged_outputs.resolved`
- `ops_admin.prompt_versions.rollout`
- `ops_admin.feature_flags.updated`

### Mandatory properties for every ops_admin.* event

Add to the spec §9 preamble (applies to all 8 events; do not
duplicate per-event):

- `request_id` (TEXT — Edge Function `x-request-id` value) — cross-
  system join key per canonical-properties.md §7.
- `actor_id` (string — Supabase Auth user UUID for human admins;
  reserved `system:<source>` for non-human actors per
  canonical-properties.md §3) — source of truth for action attribution.

### Property name normalization (per-event diff)

| Event | Spec §9 (current) | Replace with | Why |
|---|---|---|---|
| All `users.*` | `target_canonical_user_key_hash` | `canonical_user_key_hash` | Canonical name per ADR 0027. Surrounding context makes the "target" framing redundant. |
| `users.list_queried` | `search_present` | `has_search` | Phase C implementation form. |
| `feature_flags.updated` | `key` | `flag_key` | More specific name; `key` is too generic for cross-event reasoning. |

### Property additions

For all **mutating** events (`users.detail_viewed`,
`users.quota_reset`, `users.status_changed`,
`users.force_reauth`, `flagged_outputs.resolved`,
`prompt_versions.rollout`, `feature_flags.updated`):

- `audit_id` (UUID) — the `audit_log.id` of the row written by the
  same handler. Lets dashboards join PostHog event → audit_log row
  for full-context drilldown.
- `target_id` (string) — surface-specific identifier (flagged-output
  UUID, prompt composite key, flag key string, etc.). **Never** the
  raw `canonical_user_key` for user-scoped events; user identity
  uses `canonical_user_key_hash` per the PII rule.

For `users.list_queried` specifically:
- `result_count` (integer ≥ 0) — page-size of returned rows.
  Distinct from `total_count` (filtered-across-pages total). Per
  Phase C amendment commit `35e077a`.

For `users.status_changed` specifically:
- `from_status` (string | null) — prior status from
  `result.before.status` snapshot.

For `users.force_reauth` specifically:
- `merged_siblings_bumped` (integer ≥ 0) — fan-out count of merged
  sibling rows updated by the cascade. RPC
  `stir_ops_force_reauth` returns this (W39, migration
  `20260424000006`).

For `feature_flags.updated` specifically:
- `noop` (boolean) — `true` when the request had no mutating fields
  (early-return branch). Lets dashboards distinguish meaningful
  toggles from no-op admin actions.
- `is_enabled`, `rollout_pct` (each optional) — present only when
  the corresponding params field was set. `null` when unchanged.

For `flagged_outputs.resolved` specifically:
- `resolution_action` (string enum — `dismissed | withdrawn |
  canned_fallback_pinned`) — the resolution path taken.
- `feature_key` (string) — pulled from the flagged row's
  `feature_key`, NOT from request params (`params.action` is the
  resolution enum, not the feature).

For `prompt_versions.rollout` specifically:
- `feature_key`, `version`, `rollout_pct`, `is_default` — match the
  request params verbatim.

---

## §Gaps — items resolved by this bundle (remove)

The following gaps the spec was tracking are closed:

- **"ops_admin.* events specified in §9 but not emitted in code"** —
  Closed by commit `8635c61` (Phase C). All 8 events emit at the
  writeAudit seams.
- **"alerts.md references properties not emitted by production
  code"** (the `cook_turn_resolved.preamble_present_rate` and
  `sync_state_changed.state` drift findings from Phase A audit
  G5 + G6) — Phase F rewrites those alerts in
  `docs/sentry/alerts.md`. The synchronization-discipline rule
  (canonical-properties.md §10) prevents recurrence.

---

## §Gaps — items still open (move to §Deferred or keep)

These remain after this bundle. Decision per item:

- **iOS Sentry `canonical_key_hash` rename** (3 captureError + 4
  breadcrumb sites). Trigger: next organic touch of the owning
  Swift file. Filed in canonical-properties.md §9 deprecation
  table; ALSO filed in CLAUDE.md §Deferred per the existing
  pattern (G4 entry).
- **Three handlers emit zero PostHog** (`session-bootstrap`,
  `revenuecat-webhook`, `ops-flag-output`). Trigger per Daniel's
  scope call: "before unified observability dashboard ships, these
  three handlers must emit." Filed in CLAUDE.md §Deferred (G8 entry).
- **PostHog emit unit-test infrastructure** (mock ingest server or
  module-rewrite seam). Trigger: when test-time wire-shape
  assertions become higher-leverage than review-time discipline.
  Filed as proposal in `Backend/supabase/tests/telemetry_canonical_test.ts`
  header.

---

## Notes

The schema rules themselves (canonical name choice, dual-id model,
event-name conventions, PII bans, synchronization discipline) live
in repo. The spec should reference, not duplicate, those:

```markdown
> Telemetry conformance: every PostHog event and Sentry capture in
> Stir conforms to the canonical property schema documented in the
> repo at `docs/telemetry/canonical-properties.md` (decision: ADR
> 0027). New events / alerts must follow the canonical-schema
> reviewer checklist (see `docs/runbooks/telemetry-canonical-schema.md`).
```

This footer/reference link in spec §9 keeps the spec at-a-glance
canonical-aware without duplicating the schema's contents.
