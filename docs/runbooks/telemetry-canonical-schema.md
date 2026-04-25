# Runbook: telemetry canonical schema

**Purpose.** Day-to-day operator reference for Stir's PostHog and
Sentry property contract. The detailed reference is
`docs/telemetry/canonical-properties.md` (and ADR 0027); this runbook
is the at-a-glance "I'm reviewing telemetry code, what do I check?"
sheet.

## Reviewer checklist

Paste into PR comments when a PR adds or modifies a PostHog event,
Sentry capture, or alert rule:

```
Telemetry canonical-schema checklist:
[ ] Every new emit includes `canonical_user_key_hash` (when user-scoped)
[ ] Every new backend emit includes `request_id` (or documents cron
    carve-out per canonical-properties.md §7.1)
[ ] Every new admin emit includes `actor_id` (UUID for human admins,
    `system:<source>` for non-human actors)
[ ] No banned PII fields (see canonical-properties.md §6 — never
    `actor_email`, raw `canonical_user_key`, `$ai_input`,
    `$ai_output_choices`, recipe titles, transcripts)
[ ] If this adds an event to spec §15 / CLAUDE.md, the emit landed
    in the same commit OR is in a "Proposed (not yet emitted)"
    section
[ ] If this adds an alert rule to docs/sentry/alerts.md, the
    `Emit source:` line cites file + symbol where the referenced
    property is emitted
```

## When the discipline trips

The Phase A audit (2026-04-24) found two alert rules referencing
properties not emitted by production code
(`cook_turn_resolved.preamble_present_rate`;
`sync_state_changed.state`). Pattern: spec / alerts / runbooks
written ahead of code drift permanently because nothing forces
sync.

If you're adding to spec §15, CLAUDE.md §Telemetry events, or
`docs/sentry/alerts.md` without a matching emit on disk:

- **Spec / CLAUDE.md:** land under a `## Proposed (not yet emitted)`
  subsection. Move out when the implementation lands.
- **alerts.md:** land with `Emit source: UNIMPLEMENTED (TODO)` so a
  grep finds the gap. Move to `Emit source: <file>:<symbol>` when
  the implementation lands.

## Identity — use `canonical_user_key_hash`

The 16-char SHA-256 prefix of `canonical_user_key`. Use this name
on every PostHog property + every Sentry tag.

Two deprecated names await organic-touch migration (see
canonical-properties.md §9):

- `canonical_key_hash` on iOS Sentry context dicts (3 captureError +
  4 breadcrumb sites in RootCoordinator / SupabaseSessionClient /
  CookModeViewModel) — rename when next touched for any Sentry-related
  reason.
- `user_hash` on backend SQL Sentry — **migrated** in
  `20260424000007_cost_anomaly_dispatch_canonical_tags.sql` (Phase D).

## Cross-system join key — `request_id`

`request_id` (TEXT — UUID or `voice:<session>:<turn>`) is the
canonical join key. Sourced from Edge Function `x-request-id`
header via `_shared/logger.ts:requestIdFrom`. Echoed on the response.

Cron-invoked or other system-driven surfaces (no HTTP request scope)
**omit** `request_id`. The surface's row primary key
(`cost_anomalies.id` for cost anomaly dispatch) becomes the
surface-specific cross-system join key. Carve-out documented in
canonical-properties.md §7.1.

## Identifying system-driven events

Every emit that isn't user/admin-driven should set
`actor_id = 'system:<source>'`:

- `system:cron` — pg_cron-invoked dispatch
- `system:webhook` — reserved for incoming webhooks (RevenueCat etc.)
- `system:worker` — reserved for pgmq-dispatch-style background workers

Omitting `actor_id` reads as "we don't know who acted" — strictly
preferred to set the system-actor value instead. Cross-system joins
on `actor_id` then distinguish admin-driven events from automated
ones cleanly.

## Where to look when something's off

- **An alert isn't firing:** check `Emit source:` in the alert
  definition. Grep the source file for the property name. If
  missing, the emit was never wired (rule violation; fix at the
  emit site, not by removing the alert).
- **Dashboard cost numbers diverge from `ai_request_log`:** run
  the reconciliation query in ADR 0009 §Notes (`SELECT SUM(cost_usd)
  FROM ai_request_log GROUP BY feature_key` should match PostHog
  cost-by-feature within ±1%).
- **Sentry events from cost anomaly dispatch lost:** two-phase
  dispatch debugging in `docs/runbooks/cost-anomaly.md`; tag-related
  changes (rename, addition) in canonical-properties.md §9 Migrated
  names.

## Reference

Authoritative documents:

- `docs/decisions/0027-telemetry-canonical-property-schema.md` —
  the decision record (why these rules)
- `docs/telemetry/canonical-properties.md` — the living schema
  (what the rules are)
- `docs/telemetry/2026-04-24-audit.md` — the audit that motivated
  the schema (how we got here)
- ADR 0009 — PostHog LLM Observability dual-write (the prior
  property contract for AI events)
