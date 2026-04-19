# Runbook — Gemini service account provisioning (step 6.0)

**Purpose.** One-time setup for the Google Cloud service account that authenticates Gemini Live ephemeral-token minting. Prereq for step 6 backend code.

**Related.** ADR 0006 (OAuth service-account mint) · `docs/validation/step-6-cheap-half-drift-check.md` · CLAUDE.md §Gemini Live sharp-edges #16.

**Outcome.** `GCP_SERVICE_ACCOUNT_JSON` set in Supabase prod secrets. Edge Function code can exchange that JSON for a Bearer access token and call `POST /v1alpha/auth_tokens`.

---

## Prereqs

- GCP billing account that the existing Gemini API budget is attached to (the API key is billed there already).
- Owner / Security-Admin access on that billing account — only needed for the service-account create + role bind steps.
- `gcloud` CLI (`brew install google-cloud-sdk`) or the GCP Console if you prefer clicks.

Log in once:

```
gcloud auth login
```

---

## Steps

### 1. Identify (or create) the GCP project

Find the project the current Gemini API key lives in:

```
gcloud projects list --filter="name:stir* OR name:*gemini*" --format="value(projectId,name)"
```

If there's no Stir project yet — create one under the existing billing account:

```
gcloud projects create stir-prod --name="Stir"
gcloud beta billing projects link stir-prod --billing-account <ACCOUNT_ID>
```

If a project already owns the Gemini key (likely — `GEMINI_API_KEY` had to come from somewhere), reuse it. Record the project id.

For the rest of this runbook: **export it** so the commands work verbatim.

```
export STIR_GCP_PROJECT=<projectId>
```

### 2. Enable the Generative Language API on that project

Idempotent. Safe to re-run.

```
gcloud services enable generativelanguage.googleapis.com --project "$STIR_GCP_PROJECT"
```

### 3. Create the service account

```
gcloud iam service-accounts create stir-live-mint \
  --description="Mints Gemini Live ephemeral tokens for Stir Cook Mode voice" \
  --display-name="Stir Live Mint" \
  --project "$STIR_GCP_PROJECT"
```

The SA email will be: `stir-live-mint@$STIR_GCP_PROJECT.iam.gserviceaccount.com`. Record it.

```
export STIR_SA_EMAIL="stir-live-mint@$STIR_GCP_PROJECT.iam.gserviceaccount.com"
```

### 4. Grant the minimum role

The Generative Language API checks for the `aiplatform.user` role in v1alpha. If that role grant fails to grant mint permission (unlikely, but Google moves the cheese here), fall back to `generativelanguage.admin` and note in ADR 0006.

Start with the narrow role:

```
gcloud projects add-iam-policy-binding "$STIR_GCP_PROJECT" \
  --member="serviceAccount:$STIR_SA_EMAIL" \
  --role="roles/aiplatform.user"
```

If later smoke test returns 403 on mint, run this too:

```
gcloud projects add-iam-policy-binding "$STIR_GCP_PROJECT" \
  --member="serviceAccount:$STIR_SA_EMAIL" \
  --role="roles/generativelanguage.admin"
```

### 5. Create and download the JSON key

```
gcloud iam service-accounts keys create ~/stir-sa-key.json \
  --iam-account "$STIR_SA_EMAIL" \
  --project "$STIR_GCP_PROJECT"
```

**Do not commit this file.** It's in the user home dir; treat like the main Gemini key.

### 6. Upload to Supabase prod secrets

Compact-serialize the JSON so it fits on one env-var line, then set:

```
cd /Users/danny/Documents/Codez/Apps/Stir/Backend
SA_JSON=$(jq -c . < ~/stir-sa-key.json)
supabase secrets set "GCP_SERVICE_ACCOUNT_JSON=$SA_JSON" --project-ref ktqajarcomzplnpbczfo
```

Confirm via digest:

```
supabase secrets list --project-ref ktqajarcomzplnpbczfo | grep GCP_SERVICE_ACCOUNT_JSON
```

### 7. Delete the local copy of the JSON

Once it's in Supabase, the local file is a liability.

```
shred -u ~/stir-sa-key.json 2>/dev/null || rm ~/stir-sa-key.json
```

### 8. Tell Claude to proceed

Once the secret is set, I'll run a smoke test against `POST /v1alpha/auth_tokens` with Bearer auth from a throwaway Edge Function (same spike pattern as the drift check), confirm a token comes back, and then proceed with the real `ai-realtime-session` endpoint.

---

## Rollback / failure modes

- **Step 4 role grant fails with "not found".** The role name changed; check `gcloud iam roles list --filter="name~aiplatform OR name~generativelanguage"` and pick the user-level role from the list.
- **Step 6 secret set prompts for confirmation.** That's expected the first time; respond `y`.
- **Smoke test returns 403 after step 7.** Add the broader `generativelanguage.admin` role per step 4 fallback.
- **Smoke test returns 401.** Check SA JSON wasn't truncated during the env-var set; re-run step 6 if so.

## Rotation

Service account keys don't auto-expire. Rotate every 90 days (matching the RevenueCat webhook secret cadence). Rotation runbook: `docs/runbooks/gemini-service-account-rotation.md` (to be written after the first successful mint).
