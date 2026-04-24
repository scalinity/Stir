# Stir Ops Console

Admin SPA for user lookup, cost anomaly review, flagged-output resolution,
prompt rollout, feature flag toggles, audit log. Step 8 Phase 8.

## Run locally

```bash
cd ops
cp .env.example .env.local
# Paste VITE_SUPABASE_ANON_KEY from the Supabase dashboard
npm install
npm run dev
# open http://localhost:5173
```

Sign in with your email (must be in `ops_admins` table — see
`docs/runbooks/ops-admin-provisioning.md`).

## Pages

| Path | Status |
| --- | --- |
| `/` Dashboard | Shipped (KPI cards) |
| `/users` Users | Shipped (list + force_reauth / reset_quota / ban) |
| `/flagged` Flagged Outputs | Shipped (dismissed / withdrawn / canned_fallback_pinned) |
| `/anomalies` Cost Anomalies | Shipped (severity filter + detail view) |
| `/voice` Voice Sessions | Deferred to step-9 polish |
| `/flags` Feature Flags | Deferred to step-9 polish |
| `/prompts` Prompt Versions | Deferred to step-9 polish |
| `/audit` Audit Log | Deferred to step-9 polish |

Every page hits `POST /v1/ops/admin` with a typed action + params payload.
Backend action handlers ship in `Backend/supabase/functions/ops-admin/index.ts`.

## Auth

Supabase Auth magic-link. See ADR 0023 for the admin JWT vs iOS session
JWT separation design. `_shared/admin_auth.ts` triple-gates every request
(iss + aud + ops_admins lookup).

## Deploy

Step 9 — host via Edge Function + Supabase Storage bucket (see ADR 0024).
For step 8 demo, `npm run dev` against the prod Supabase URL is enough.
