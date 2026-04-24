# Sentry alerts

Each of these is configured manually in the Sentry UI (project: Stir). Sentry's alert API is undocumented-stable and not worth round-tripping; this file is the source of truth for what SHOULD exist + the thresholds.

All alerts reference spec §13 "Observability — Alerts".

## Backend alerts

### ai-request-failure-rate
- **Condition:** `event.type == 'ai_request_failed'` count > 5% of `ai_request_completed` count over 15-min window
- **Threshold:** warn at >5%, critical at >10%
- **Channel:** Slack `#stir-ops`
- **Mute:** 4h silence window

### live-api-fallback-share
- **Condition:** `cook_turn_submitted.path == 'gemini_fallback'` / total `cook_turn_submitted` > 10% over 30 min
- **Severity:** warn
- **Channel:** Slack `#stir-ops`
- **Notes:** cost_turn_resolved error flag is a separate metric

### voice-session-tokens-p95
- **Condition:** `voice_session_token_snapshot.cumulative_tokens` p95 > 50,000 in a 30-min rolling window
- **Severity:** critical
- **Channel:** page Daniel via PagerDuty (step 9 polish)
- **Rationale:** pruning is failing → cost blowup imminent

### preamble-present-rate
- **Condition:** `cook_turn_resolved` where `path=live_api` + `result_type=tool_call`: preamble_present_rate < 90% over 1-hour window
- **Severity:** warn
- **Channel:** Slack `#stir-ops`

### hard-rule-violation
- **Condition:** `ai_request_completed.feature_key=substitution` where allergen flag in telemetry event = true, count > 0 over ANY window
- **Severity:** critical
- **Channel:** page Daniel immediately
- **Rationale:** spec §16 "0 allergen violations observed" — this is legally sensitive

### ai-cost-per-user
- **Condition:** `$ai_generation.total_cost_usd` SUM per user_hash over 24h: Premium > $3 OR Pro > $8 OR any > $10
- **Severity:** warn (Premium 2x), critical (hard cap)
- **Channel:** backed by `cost_anomalies` table + `stir_ops_cost_anomaly_alert_dispatch` pg_cron job (step 8 P5) — Sentry event already wired via pg_net. This alert row exists in Sentry UI as a confirmation route (event capture → alert rule → notification), not as a primary detection path.

### cloudkit-sync-error
- **Condition:** `sync_state_changed.state == 'error'` count > 3% of total sessions over 30 min
- **Severity:** warn
- **Channel:** Slack `#stir-ops`

### crash-free-sessions
- **Condition:** Sentry-native release health → crash-free sessions < 99.2% over 24h
- **Severity:** warn at 99.0%, critical at 98.0%
- **Channel:** Slack `#stir-ops`

### payment-confirmation-lag
- **Condition:** `purchase_started` → `purchase_completed` latency p95 > 10 min over 1-hour window
- **Severity:** warn
- **Channel:** Slack `#stir-ops`

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
