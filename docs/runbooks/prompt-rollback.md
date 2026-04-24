# Runbook: prompt rollout + rollback

**Owner:** Daniel. **Source of truth:** spec §13 "Model / prompt rollback".

## Canary a new prompt version

1. Create the new `prompt_versions` row via a migration (new version string, `is_default=false`, `rollout_pct=5`).
2. Deploy migration: `supabase db push`.
3. Verify: ops console → Prompt Versions page shows the new row at 5% rollout.
4. Watch for 1 hour:
   - Sentry: zero hard-rule violations (substitution allergen leaks, dinner_solve dietary violations)
   - PostHog: `ai_request_failed` rate for the feature
   - Ops console → Cost Anomalies: no new critical rows attributable to the feature
5. If clean, promote: ops console → Prompt Versions → `<feature>@<version>` → set rollout_pct = 25%.
6. Repeat at 50% → 100%.
7. At 100%, check `is_default` on the new row (ops console → set_default toggle; the router auto-clears `is_default` on sibling rows).

## Automatic rollback triggers (spec §13)

If any of these fire on a canary, pull it immediately:

- Hard-rule violation count > 0 (allergen leak, dietary violation) — CRITICAL
- Fallback rate doubles vs baseline — WARN
- User thumbs-down rate > 15% above baseline — WARN
- p95 latency > SLO for 30 min — WARN
- `voice_session_tokens_p95` spikes >30% above baseline — CRITICAL (pruning regression)

## Rollback

1. Ops console → Prompt Versions.
2. Find the problematic version → set rollout_pct = 0.
3. Find the prior-known-good version → set rollout_pct = 100, is_default = true.
4. Effect: next AI call within 30s (iOS config-bootstrap poll cadence) uses the prior version.

## Emergency: disable the whole feature

If rollback-to-prior doesn't fix (e.g., the bug is in the codepath, not the prompt):

- Ops console → Feature Flags → flip the relevant kill switch (`disable_scan_parse`, `disable_cook_realtime`, `disable_imports`, `force_saved_meals_only`).
- Users see AI-01 / IMPORT-01 / AI-VOICE-01 with degraded-mode copy per spec §6.
- Fix the codepath in a patch release, deploy, flip the flag back off.

## Audit trail

Every prompt rollout + rollback writes to `audit_log` with:
- `action = 'prompt_versions.rollout'`
- `actor_id` + `actor_email` = admin who made the change
- `before` / `after` = full row snapshots
- `target_id = '<feature_key>@<version>'`

Query: ops console → Audit Log page (step 9).
