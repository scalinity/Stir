# Runbook: STIR_JWT_SECRET rotation

**Owner:** Daniel. **Trigger:** suspected secret compromise, annual rotation,
routine key hygiene before a major release.

## Why rotation is sensitive

`STIR_JWT_SECRET` is the HS256 signer for iOS session JWTs AND the verifier
that Supabase PostgREST uses for RLS. It MUST equal the Supabase project's
legacy `jwt_secret` at all times — any drift between the two causes every
authenticated request to fail with `AUTH-01 reason=signature_invalid` and
RLS to deny-all.

Because the same secret is used to sign iOS session JWTs and verify
Supabase Auth admin JWTs (via `_shared/admin_auth.ts`), rotation affects
both surfaces simultaneously.

## Before starting

Announce the rotation in the ops channel. Expected user-facing impact:
every iOS app in the wild silently re-bootstraps on the next `/v1/*`
request (AUTH-01 reason=signature_invalid → silent re-mint). The SPA
ops console force-signs-out every admin. Admin re-login is a magic-link
flow; allow ~60s per admin.

Confirm the current secret matches between Supabase and Edge Functions:

```sh
# Supabase side:
supabase secrets list --project-ref ktqajarcomzplnpbczfo
# Expect: STIR_JWT_SECRET present

# Locally (for reference):
cat Backend/supabase/functions/.env | grep STIR_JWT_SECRET
```

## Rotation procedure

### 1. Generate a new secret

```sh
# 32 bytes, base64url (matching Supabase's format):
openssl rand -base64 32 | tr '/+' '_-' | tr -d '='
```

Store the new value somewhere secure (1Password, password manager).

### 2. Rotate the Supabase project JWT secret

Supabase Dashboard → Settings → API → JWT Settings → click "Generate a new
secret". Copy the new `legacy_jwt_secret`.

(Do NOT rotate the Edge Function secret yet — if it drifts ahead of the
project, every Edge Function deploy hits signature_invalid until Step 3.)

### 3. Rotate the Edge Function secret

```sh
supabase secrets set STIR_JWT_SECRET="<new_secret>" --project-ref ktqajarcomzplnpbczfo
```

Because Edge Functions read env at module load, the new value takes effect
on each function's next cold start. To force immediate rollover, redeploy
each JWT-verifying function:

```sh
for fn in session-bootstrap config-bootstrap push-register \
          dinner-solve pantry-parse substitution grocery-generate \
          cook-turn recipe-import realtime-session voice-turn-usage \
          ops-flag-output ops-admin; do
  supabase functions deploy "$fn" --project-ref ktqajarcomzplnpbczfo
done
```

### 4. Force reauth on every admin

Newly-minted Supabase Auth admin JWTs are signed with the new secret so
they verify cleanly. But any ops admin with a session open at rotation
time holds a pre-rotation JWT — all their ops-admin calls will 401 with
AUTH-01. Notify admins to refresh the SPA; their in-memory session is
replaced by the auto-refresh pathway or a new magic-link.

### 5. Expected iOS UX

Every iOS JWT signed under the old secret now fails `jwt.verify` →
AUTH-01 reason=signature_invalid. Per ADR 0023, iOS handles this with
a silent re-bootstrap: clear cached JWT → POST /v1/session/bootstrap →
retry the original request. User-visible impact is one round-trip of
latency on the first affected request. No sign-in flow required.

**Operational note — Sentry will spike during rotation.** iOS logs
`signature_invalid` at `error` severity and captures to Sentry via
`SupabaseSessionClient.logAuth01()` at `Stir/Core/Services/
SupabaseSessionClient.swift:548`. This is intentional — under normal
operation, a signature_invalid means either a client bug or secret
rotation, both warranting operator attention. During a planned
rotation, expect ~1 Sentry signature_invalid event per active iOS
app in the wild, clustered within ~60 minutes of the rotation
completing (bounded by the JWT TTL at 24h — stale JWTs only hit
the failure mode on their next outbound request). Silence Sentry
alerts for `auth_reason=signature_invalid` during the rotation
window, or file the spike as an expected event linked to this
runbook execution. Do NOT page oncall for the spike — the iOS
silent-retry recovers every user automatically.

### 6. Verify

```sh
# Hit a JWT-verifying endpoint from a fresh iOS simulator:
curl -X POST https://ktqajarcomzplnpbczfo.supabase.co/functions/v1/session/bootstrap \
  -H 'apikey: <anon_key>' \
  -H 'content-type: application/json' \
  -d '{"installation_id":"'"$(uuidgen)"'"}'

# Confirm response contains session_jwt and decode it:
echo "<session_jwt>" | awk -F. '{print $2}' | base64 -d 2>/dev/null | jq .
# iss should be "stir-backend"; signature verifies under new secret.
```

### 7. Update local dev

```sh
# Update Backend/supabase/functions/.env (local only, never committed):
sed -i '' 's/STIR_JWT_SECRET=.*/STIR_JWT_SECRET=<new_secret>/' Backend/supabase/functions/.env
supabase stop && supabase start
```

## Rollback

If any critical path breaks:

```sh
# Revert Supabase JWT setting:
# Dashboard → Settings → API → JWT Settings → paste old legacy_jwt_secret

# Revert Edge Function secret:
supabase secrets set STIR_JWT_SECRET="<old_secret>" --project-ref ktqajarcomzplnpbczfo

# Redeploy the JWT-verifying functions again to pick up the old value.
```

iOS clients that successfully re-bootstrapped during the broken window
have JWTs signed under the new secret; those will fail after the
rollback too. Their next request silent-re-bootstraps. No manual
intervention required.

## Post-rotation checklist

- [ ] `supabase secrets list` shows the new STIR_JWT_SECRET.
- [ ] A fresh iOS bootstrap succeeds end-to-end.
- [ ] An ops admin can sign in via magic-link and hit an admin RPC.
- [ ] `SELECT COUNT(*) FROM audit_log WHERE action='jwt.rotated';` —
      optionally write a manual audit_log entry documenting the rotation.
- [ ] Sentry: AUTH-01 `signature_invalid` rate returns to baseline within
      1 hour (every iOS app should have re-bootstrapped by then).
