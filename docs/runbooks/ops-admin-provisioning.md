# Runbook: provisioning ops admins

**Owner:** Daniel. **Audience:** Daniel + future oncall.

## Add an admin

1. Ask the person to sign in once at the ops console (`localhost:5173` or prod URL). The magic-link flow creates an `auth.users` row.
2. In the Supabase dashboard SQL editor (prod project `ktqajarcomzplnpbczfo`):
   ```sql
   INSERT INTO public.ops_admins (auth_user_id, email, notes)
   SELECT id, email, 'seeded 2026-MM-DD by Daniel'
     FROM auth.users WHERE email = 'NEW_ADMIN@example.com';
   ```
3. Tell the person to refresh their ops console tab; admin actions should now succeed.

## Remove an admin

```sql
DELETE FROM public.ops_admins WHERE email = 'EX_ADMIN@example.com';
```
- Does NOT delete the `auth.users` row (audit trail stays).
- Existing admin JWTs remain valid until their TTL (1 hour). If you need immediate cutoff:
  - Delete the ops_admins row (above).
  - In the dashboard, sign the user out of every Supabase Auth device (Auth → Users → …).

## Rotate APNs secrets

APNs provider key (`APNS_AUTH_KEY_P8`) has no expiry but should rotate if compromise is suspected.

1. Generate a new key in Apple Developer account (Certificates, Identifiers & Profiles → Keys).
2. Download the `.p8` file.
3. Base64-encode: `cat AuthKey_<id>.p8 | base64 | pbcopy`.
4. Update secrets:
   ```bash
   supabase secrets set --project-ref ktqajarcomzplnpbczfo \
     APNS_AUTH_KEY_ID=<new_id> \
     APNS_AUTH_KEY_P8=<paste> \
     APNS_TEAM_ID=<team> \
     APNS_BUNDLE_ID=com.company.stir
   ```
5. Revoke the old key in Apple Developer.
6. pgmq-dispatch workers pick up new secrets on next cold-start (≤30 min; restart by redeploying if urgent).

## APNs environment gotcha

`device_installations.apns_environment` accepts EXACTLY `'production'` OR `'sandbox'` (enforced by CHECK constraint). iOS Debug builds send `'sandbox'`, Release builds send `'production'`. `'development'` is not a real APNs gateway and will be rejected with VAL-01 at bootstrap.

## Admin auth troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `403 BILL-01 not admin` after sign-in | `ops_admins` row missing | Run the INSERT above |
| `401 AUTH-01 reason=wrong_issuer` | iOS JWT used instead of admin JWT | Sign in via magic link (ops console), not iOS app |
| `401 AUTH-01 reason=expired` | Admin JWT > 1h old | Tab will silently refresh via Supabase Auth; if not, sign out + back in |
| `401 AUTH-01 reason=not_admin` | (same as first row but at the Edge Function gate) | Run INSERT |

See ADR 0023 for the full design + triple-gate rationale.
