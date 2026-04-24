# IP Salt Rotation Runbook

**Secret:** `LOG_IP_SALT` (Supabase Edge Function environment)
**Consumers:** `_shared/rate_limiter.ts` `ipBucket()` → `realtime-session/index.ts` `userLog.warn('rate_limited', { source_ip_bucket })`
**Cadence:** monthly (first business day of the month).
**Owner:** Daniel (solo) until step-9 ops scales to multi-admin.

## Why rotate

The salt is what makes `ipBucket()` privacy-grade instead of trivially reversible. Without rotation, an attacker with long-window log access + the ability to brute-force ~4 billion IPv4 candidates (seconds on a laptop) can reconstruct a rainbow table from bucket → IP that stays valid indefinitely. Monthly rotation bounds the attack window.

## First-time setup (pre-beta)

1. Generate a 32-byte salt:
   ```bash
   openssl rand -hex 32
   ```
   Copy the output.
2. Set on prod:
   ```bash
   supabase secrets set --project-ref ktqajarcomzplnpbczfo LOG_IP_SALT=<hex-from-step-1>
   ```
3. Verify:
   ```bash
   supabase secrets list --project-ref ktqajarcomzplnpbczfo | grep LOG_IP_SALT
   ```
4. Redeploy `realtime-session` to pick up the env (or wait for the next deploy; edge functions refresh env on cold start, which is usually within 1 deploy + 1h of idle):
   ```bash
   supabase functions deploy realtime-session --project-ref ktqajarcomzplnpbczfo
   ```
5. Smoke test: make a rate-limited realtime-session request (or just any request). Check the edge function log — `source_ip_bucket` should now read `ip_<16hex>` (not `unsalted:<8hex>`).

If the log still shows `unsalted:`, the salt didn't propagate. Check:
- Did the deploy succeed? (`supabase functions list --project-ref ktqajarcomzplnpbczfo`)
- Is `LOG_IP_SALT` listed in the secrets dashboard?
- Is the `[rate_limiter] LOG_IP_SALT not set ...` warning in the function log? (Once-per-process; restart the function.)

## Monthly rotation

Cadence: first business day of the month.

1. Generate a fresh 32-byte salt:
   ```bash
   openssl rand -hex 32
   ```
2. Stage the new salt with a 24h overlap (old + new both present).

   Option A — single-salt rollover (simpler; accepts a 24h gap in bucket continuity for the rate_limited log line only, which is acceptable because rate-limit events are low-volume and dashboard continuity across the rollover doesn't affect observability much):
   ```bash
   supabase secrets set --project-ref ktqajarcomzplnpbczfo LOG_IP_SALT=<new-hex>
   supabase functions deploy realtime-session --project-ref ktqajarcomzplnpbczfo
   ```

   Option B — dual-salt overlap (future work; requires code change to accept `LOG_IP_SALT_CURRENT` + `LOG_IP_SALT_PREVIOUS` and try both on read). Not implemented yet; revisit if rate-limit event volume grows to where bucket continuity at rollover becomes a real need.

3. Smoke test as above.

4. Log the rotation in `docs/runbooks/secret-rotation-log.md` (create if missing):
   ```
   2026-MM-DD | LOG_IP_SALT rotated | Daniel | option A
   ```

## If the secret leaks

1. Generate a new salt immediately (`openssl rand -hex 32`).
2. `supabase secrets set LOG_IP_SALT=<new>`.
3. Redeploy `realtime-session`.
4. New buckets are computed with the new salt; old buckets in old log lines remain attacker-recoverable until log retention cycles past the leak window.
5. If the leak is "sensitive" (e.g., actively exploited), consider shortening log retention from default to accelerate cycling — but the usual retention-period truncation is the right first response.

## If `LOG_IP_SALT` is ever unset

The function's `_shared/rate_limiter.ts` falls back to `unsalted:<fnv1a-8hex>` with a once-per-process stderr warning. Dashboards that want to surface the misconfig can query for `source_ip_bucket LIKE 'unsalted:%'` — any non-zero count for ≥1h is a real alert.

To clear the fallback:
1. Follow "First-time setup" above.
2. Confirm the stderr warning stops (process restart typically clears; or wait until next cold start).

## Non-goals

- This runbook does NOT address IP logging in other contexts (Apple IAP webhook logs, Sentry breadcrumbs, PostHog $ip auto-capture). Those are separately governed by the respective SDK's privacy posture and/or Apple's data-retention rules.
- This runbook does NOT claim to prevent IP inference across correlated events — even with a rotated salt, an attacker correlating timing + frequency across events attributed to the same bucket can sometimes re-identify a user by behavioral pattern. That's a correlation risk, not a bucketing-function risk, and is out of scope for this rotation.

## References

- `_shared/rate_limiter.ts` — the function itself
- CLAUDE.md §Deferred → "Source-IP HMAC with rotated salt" (owner-step 9, shipped 2026-04-24)
- Step-6 review P2-C (original filing)
