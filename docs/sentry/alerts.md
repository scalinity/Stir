# Sentry alerts

Each of these is configured manually in the Sentry UI (project: Stir). Sentry's alert API is undocumented-stable and not worth round-tripping; this file is the source of truth for what SHOULD exist + the thresholds.

All alerts reference spec §13 "Observability — Alerts".

**Synchronization discipline (added 2026-04-24, ADR 0027):** every alert below carries an `Emit source:` line citing the file + symbol where the queried property is emitted by production code. Adding a new alert without an `Emit source:` line is banned — see `docs/runbooks/telemetry-canonical-schema.md` for the reviewer checklist. If the implementation doesn't exist yet, land the alert with `Emit source: UNIMPLEMENTED (TODO: <ticket or owner>)` so grep finds the gap.

## Backend alerts

### ai-request-failure-rate
- **Condition:** `event.type == 'ai_request_failed'` count > 5% of `ai_request_completed` count over 15-min window
- **Threshold:** warn at >5%, critical at >10%
- **Channel:** Slack `#stir-ops`
- **Mute:** 4h silence window
- **Emit source:** `Stir/Features/Scan/ScanViewModel.swift` (and other AI feature view models — `ai_request_failed` is emitted on every AI-call failure path)

### live-api-fallback-share
- **Condition:** `cook_turn_submitted.path == 'gemini_fallback'` / total `cook_turn_submitted` > 10% over 30 min
- **Severity:** warn
- **Channel:** Slack `#stir-ops`
- **Notes:** cost_turn_resolved error flag is a separate metric
- **Emit source:** `Stir/Features/CookMode/CookModeViewModel.swift:emitCookTurnResolved` (path is on `cook_turn_resolved`, not `cook_turn_submitted` — see TODO below)
- **TODO (Phase F audit, 2026-04-24):** the alert names `cook_turn_submitted.path` but the `path` property is currently emitted only on `cook_turn_resolved` (see `emitCookTurnResolved`). Either rewrite the alert to query `cook_turn_resolved` OR add `path` to the `cook_turn_submitted` emit. Filed at audit time, not part of telemetry-bundle scope.

### voice-session-tokens-p95
- **Condition:** `voice_session_token_snapshot.cumulative_tokens` p95 > 50,000 in a 30-min rolling window
- **Severity:** critical
- **Channel:** page Daniel via PagerDuty (step 9 polish)
- **Rationale:** pruning is failing → cost blowup imminent
- **Emit source:** `Stir/Features/CookMode/CookModeViewModel.swift:1310` (`voice_session_token_snapshot` carries `cumulative_tokens` per Phase A audit verification G7)

### preamble-present-rate
- **Condition:** `cook_turn_resolved` where `path=live_api` + `result_type=tool_call`: preamble_present_rate < 90% over 1-hour window
- **Severity:** warn
- **Channel:** Slack `#stir-ops`
- **Emit source:** **UNIMPLEMENTED** (Phase A audit G5: `preamble_present_rate` is not emitted by `CookModeViewModel.emitCookTurnResolved`. Property exists only in `Stir/Features/VoiceDiagnostics/VoiceDiagnosticsView.swift:187` — debug surface — and `Backend/evals/cook_turns/run.ts:23` — eval harness. Production `cook_turn_resolved` emits only `latency_ttfa_ms`, `latency_total_ms`, `barge_in`, `path`, `result_type`, `error_code`.)
- **TODO:** decide whether to (a) add `preamble_present_rate` to the production `emitCookTurnResolved` (iOS-side change; out of scope for the telemetry-wiring bundle), OR (b) replace this alert's predicate with one against properties currently emitted (e.g., `tool_call` turn count itself, with no rate). Filed in CLAUDE.md §Deferred under the iOS follow-up entry.

### hard-rule-violation
- **Condition:** `ai_request_completed.feature_key=substitution` where allergen flag in telemetry event = true, count > 0 over ANY window
- **Severity:** critical
- **Channel:** page Daniel immediately
- **Rationale:** spec §16 "0 allergen violations observed" — this is legally sensitive
- **Emit source:** **UNIMPLEMENTED at the property level** — `ai_request_completed` is in CLAUDE.md §Telemetry events but the per-emit shape doesn't include an `allergen_flag` property today. Production hard-rule violations are blocked at the validator before the AI response leaves the backend; the alert assumes a downstream emit that doesn't exist. Decide at next substitution-related touch.

### ai-cost-per-user
- **Condition:** `$ai_generation.total_cost_usd` SUM per user_hash over 24h: Premium > $3 OR Pro > $8 OR any > $10
- **Severity:** warn (Premium 2x), critical (hard cap)
- **Channel:** backed by `cost_anomalies` table + `stir_ops_cost_anomaly_alert_dispatch` pg_cron job (step 8 P5) — Sentry event already wired via pg_net. This alert row exists in Sentry UI as a confirmation route (event capture → alert rule → notification), not as a primary detection path.
- **Emit source:** `Backend/supabase/functions/_shared/ai_observability.ts:recordAIRequest` (`$ai_total_cost_usd` per ADR 0009 property table); `total_cost_usd` is the unprefixed alias PostHog dashboards typically use.
- **Note:** "user_hash" here refers to `distinct_id` (= `canonical_user_key_hash` per canonical-properties.md §3). Phase D renamed the SQL Sentry tag from `user_hash` → `canonical_user_key_hash` (migration `20260424000007`); the dashboard query layer uses whichever name is indexed in PostHog (distinct_id is the primary key, no rename needed there).

### cloudkit-sync-error
- **Condition:** `screen_error_shown.code == 'SYNC-01'` count > 3% of total sessions over 30 min
- **Severity:** warn
- **Channel:** Slack `#stir-ops`
- **Emit source:** `Stir/Features/CookMode/CookModeViewModel.swift:776` and other `analytics.capture(.screenErrorShown, ...)` call sites — `code` is the `ErrorCode` rawValue. SYNC-01 = "iCloud Sync isn't available" per `_shared/errors.ts`.
- **Rewrite history (Phase F, 2026-04-24):** prior condition was `sync_state_changed.state == 'error'` — Phase A audit G6 found `sync_state_changed` emits only `is_cloudkit`, no `state` property. Rewritten to query `screen_error_shown` filtered by `code: 'SYNC-01'`, which IS the canonical sync-error event in the iOS event allow-list. Original alert intent preserved; predicate corrected.

### crash-free-sessions
- **Condition:** Sentry-native release health → crash-free sessions < 99.2% over 24h
- **Severity:** warn at 99.0%, critical at 98.0%
- **Channel:** Slack `#stir-ops`
- **Emit source:** Sentry SDK auto-emit (no Stir code involved — `SentryReporter.initialize` enables `enableAutoSessionTracking`).

### payment-confirmation-lag
- **Condition:** `purchase_started` → `purchase_completed` latency p95 > 10 min over 1-hour window
- **Severity:** warn
- **Channel:** Slack `#stir-ops`
- **Emit source:** `Stir/Features/Billing/*` — both events emitted via `BillingTelemetryProperties.purchaseStarted` / `purchaseCompleted` (typed builders).

## Sentry DSN configuration

The cost_anomaly dispatch reads the Sentry DSN from `public.app_settings WHERE key='SENTRY_DSN'`:

```sql
UPDATE public.app_settings
   SET value = 'https://<public_key>@<org_id>.ingest.sentry.io/<project_id>'
 WHERE key = 'SENTRY_DSN';
```

Null value → dispatch skips alerting (local dev default); events produced by the alert rules in this file require the DSN be set.

## Adding a new alert

1. Edit this file — add a section with the four lines above (condition, severity, channel, mute).
2. Configure in Sentry UI matching exactly.
3. Smoke test: run the expected trigger (synthetic `ai_request_failed` event spike) and verify the alert fires into the expected channel.
4. Update spec §13 §Observability Alerts table if the threshold number changes.
