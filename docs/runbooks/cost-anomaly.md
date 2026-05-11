# Runbook: cost anomaly detection & response

**Owner:** Daniel.

## Thresholds (per spec §13, implemented in `stir_ops_cost_anomaly_scan`)

| Anomaly type | Trigger | Severity |
| --- | --- | --- |
| `daily_spend_2x` | Premium user > $3/day (2x expected ARPU-based) OR Pro > $8/day | warn |
| `daily_spend_hard_cap` | ANY user > $10/day (irrespective of tier) | critical |
| `voice_session_tokens_over_cap` | Single voice session (grouped by `session_id` extracted from `request_id=voice:<sid>:<turn>`) > 50K cumulative tokens | critical |
| `runaway_session` | Reserved for future detectors | warn |

## Cadence

- `stir_ops_cost_anomaly_scan()` runs every 15 min via pg_cron `stir-cost-anomaly-scan`.
- `stir_ops_cost_anomaly_alert_dispatch()` runs every 1 min via pg_cron `stir-cost-anomaly-alert-dispatch` — reads unsent anomalies + POSTs Sentry store events via pg_net, stamps `alerted_at`.
- Dedup: at most one open row per `(canonical_user_key_hash, anomaly_type)` enforced by a partial UNIQUE INDEX on `WHERE resolved_at IS NULL` (SCA-303). The legacy 24h re-emit window is gone — `resolved_at` is now load-bearing; see [`cost-anomalies.md`](./cost-anomalies.md).

## Triage

1. **Receive Sentry page** — Sentry event carries `anomaly_type`, `severity`, `user_hash` tags + `details_json` extra.
2. **Open ops console → Cost Anomalies page** → filter severity=critical or severity=warn.
3. **Click the user hash** to navigate to that user's detail view (users.detail with canonical_user_key — you'll need to unhash; see "finding user from hash" below).
4. **Inspect recent AI calls** in the user detail's `ai_recent` block — look for:
   - Single expensive Gemini call (bad prompt?)
   - Voice session with >15 turns at full-audio cost (pruning broken?)
   - Tier mismatch (free user somehow bypassing quota?)
5. **Action**:
   - Confirmed abuse → `users.status` = banned via ops console Users page
   - Product bug → file GitHub issue + flip `disable_cook_realtime` / `disable_scan_parse` kill switch if active
   - False positive → resolve anomaly via ops console (mark reviewed; this stamps `resolved_at` so the partial unique index allows future inserts of the same grain — see [`cost-anomalies.md`](./cost-anomalies.md))
   - Spend-budget tuning → edit `stir_ops_cost_anomaly_scan` thresholds in a migration

## Finding user from hash

`canonical_user_key_hash` is SHA-256 truncated to 16 hex chars. Given a hash:

```sql
-- Scan ai_request_log entries around the detection time, hash each
-- canonical_user_key, match against target.
SELECT canonical_user_key
  FROM ai_request_log
 WHERE created_at > now() - interval '24 hours'
   AND substring(encode(digest(canonical_user_key, 'sha256'), 'hex') from 1 for 16) = '<hash>'
 LIMIT 1;
```

## Kill switches

If the anomaly is systemic (many users crossing the threshold in the same hour), flip the relevant kill switch immediately via ops console → Feature Flags:

- `disable_cook_realtime` — cuts all Gemini Live; users get AI-VOICE-01 + fallback to text path
- `disable_scan_parse` — cuts pantry scan Gemini calls
- `disable_imports` — cuts recipe import Gemini calls
- `force_saved_meals_only` — cuts every AI generation path; saved meals + manual paths only

Kill switches propagate in 30s (next iOS `/v1/config/bootstrap` poll).

## Sentry DSN configuration

Cost anomaly dispatch reads the DSN from `public.app_settings WHERE key='SENTRY_DSN'` (not from Edge Function env, because pg_net runs in-DB). To set:

```sql
UPDATE public.app_settings SET value = 'https://<key>@<host>/<project_id>' WHERE key = 'SENTRY_DSN';
```

NULL value → dispatch skips quietly (local dev default).
