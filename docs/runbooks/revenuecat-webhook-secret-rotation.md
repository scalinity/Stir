# Runbook: Rotate `REVENUECAT_WEBHOOK_SECRET`

Rotate the shared secret that authenticates RevenueCat webhook deliveries. Full rotation has a brief fail-closed window (seconds) during which in-flight webhooks will 401 until RC reconfigures — acceptable for a rare, manual rotation. No dual-secret accept path exists; the handler does a single constant-time compare.

**Triggers for rotation:**

- Secret leaked into logs, transcripts, or screenshots.
- Quarterly scheduled rotation (operational hygiene; not strict).
- Pre-beta cutover (mandatory — current secret was pasted in Claude conversations during setup).
- Compromise suspected (staff turnover, laptop theft, etc.).

**Pre-rotation checklist:**

- [ ] You have the current secret (to verify auth still works after each step).
- [ ] You have access to the RevenueCat dashboard (Project Settings → Integrations → Webhooks).
- [ ] You have `supabase` CLI linked to project `ktqajarcomzplnpbczfo`.
- [ ] Nobody is running step-5 integration tests against prod (rare but flag in Slack/DM before proceeding).

---

## Step 1 — Generate the new secret

```bash
openssl rand -hex 32
```

Copy the 64-char hex string. Store it securely (1Password, Keychain, etc.) BEFORE pasting it anywhere. Never paste into a terminal with history enabled unless the next steps happen immediately.

Minimum length is enforced at 32 chars in the handler (see `Backend/supabase/functions/revenuecat-webhook/index.ts` `WEBHOOK_SECRET_MIN_LENGTH`). `openssl rand -hex 32` produces 64 chars; well above the floor.

## Step 2 — Set the new secret on Supabase

```bash
supabase secrets set REVENUECAT_WEBHOOK_SECRET='<new-64-char-hex>' --project-ref ktqajarcomzplnpbczfo
```

Verify:

```bash
supabase secrets list --project-ref ktqajarcomzplnpbczfo | grep REVENUECAT
```

Supabase shows a SHA-256 digest — the plain value is never echoed. That's fine.

## Step 3 — Redeploy the webhook function

The running function already has the OLD secret cached in memory. Redeploy to pick up the new env value:

```bash
supabase functions deploy revenuecat-webhook --no-verify-jwt --project-ref ktqajarcomzplnpbczfo
```

**From this moment until step 4 completes, RC webhook deliveries will 401.** Typical window: 30–90 seconds.

## Step 4 — Update the RevenueCat dashboard

RevenueCat dashboard → Project Settings → Integrations → Webhooks → edit the Stir webhook:

- Webhook URL: unchanged (`https://ktqajarcomzplnpbczfo.supabase.co/functions/v1/revenuecat-webhook`)
- Authorization header value: **replace with the new 64-char hex**

Save.

**The fail-closed window ends here.** RC's next delivery uses the new header.

## Step 5 — Verify end-to-end

From a shell:

```bash
curl -s -w '\n%{http_code}\n' -X POST \
  'https://ktqajarcomzplnpbczfo.supabase.co/functions/v1/revenuecat-webhook' \
  -H 'content-type: application/json' \
  -H 'Authorization: <new-64-char-hex>' \
  -d '{"api_version":"1.0","event":{"id":"rotation_smoke_001","type":"SOMETHING_UNKNOWN","app_user_id":"install:00000000-0000-4000-8000-000000000000"}}'
```

Expected: `{"received":true}` with status `200`.

Also verify the OLD secret now fails:

```bash
curl -s -w '\n%{http_code}\n' -X POST \
  'https://ktqajarcomzplnpbczfo.supabase.co/functions/v1/revenuecat-webhook' \
  -H 'content-type: application/json' \
  -H 'Authorization: <OLD-secret>' \
  -d '{"api_version":"1.0","event":{"id":"rotation_neg_001","type":"RENEWAL","app_user_id":"install:00000000-0000-4000-8000-000000000000"}}'
```

Expected: `{"error":"unauthorized"}` with status `401`.

## Step 6 — Trigger a test event from RC

RevenueCat dashboard → Integrations → Webhooks → the Stir webhook → "Send test event" (or wait for the next real delivery).

Inspect `webhook_log` in Supabase:

```sql
SELECT event_id, event_type, status, processed_at
FROM webhook_log
ORDER BY processed_at DESC
LIMIT 5;
```

Expected: the test event's row appears with `status = 'accepted'` or `'ignored'` (depending on event type). No `'signature_invalid'` rows in the window.

## Step 7 — Cleanup

- Delete the old secret from your local 1Password / notes.
- Clear shell history if the new secret was typed on the command line.
- If any automated tool (CI, staging env) held the old secret, update it now.

---

## Rollback

If step 5 verification fails (the new secret doesn't work), RC is still delivering against the dashboard value it has. Options in order of preference:

1. **Retry step 3** — the deploy sometimes takes longer than expected to propagate env changes.
2. **Revert dashboard to old secret** — put the old secret back in RC dashboard; run `supabase secrets set` with the old value; redeploy. This returns to the pre-rotation state.
3. **Escalate** — if neither works and webhooks are failing in prod, manually apply missed entitlement changes via `stir_process_webhook_event` RPC using the raw payload from RC's delivery log. Rare; only if steps 1–2 fail AND production purchases are being actively missed.

---

## Notes

- **No dual-secret accept path exists.** If we ever need zero-downtime rotation, add a `REVENUECAT_WEBHOOK_SECRET_PREVIOUS` env var and modify `verifyAuthHeader` to accept either. Don't build this speculatively; wait until a rotation is actually disrupting a user-visible flow.
- **The handler also accepts `Bearer <secret>` prefix.** RC's dashboard doesn't add `Bearer ` by default, but operators sometimes paste `Bearer abc…` by habit. Normalization handles both.
- **Related code paths:** `Backend/supabase/functions/revenuecat-webhook/index.ts:40` (env var read), `Backend/supabase/functions/_shared/revenuecat.ts:37` (`verifyAuthHeader`).
- **Related ADR:** [0003 — RevenueCat webhook uses shared-secret Authorization header](../decisions/0003-revenuecat-shared-secret-auth.md).
