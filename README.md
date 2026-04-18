# Stir

Weeknight dinner copilot for iPhone. Scan your kitchen, get three real dinner options, cook with timers and (on Premium) hands-free voice. iOS 17+, single-vendor AI on Google Gemini, Supabase backend for operations only — user content lives in CloudKit.

For the orientation pack and conventions, read `CLAUDE.md`.
For the product truth, read `Specs/Stir-Full-Spec.md`.
For Cook Mode voice architecture, read `Specs/Stir-Cook-Mode-Architecture.md`.
For the Gemini Live spike findings + step-6 drift-check plan, read `Specs/Gemini-Live-Findings.md`.

This README covers **step 1** of the build — the Supabase operational backend. iOS scaffold is step 2; AI feature endpoints land in step 3+; voice in step 6. See `CLAUDE.md` §"Build order".

---

## Repo layout

```
.
├── CLAUDE.md                       working orientation pack (highest-priority rules first)
├── README.md                       this file
├── Config.xcconfig                 (gitignored; iOS step-2 territory, do not touch yet)
├── Specs/
│   ├── Stir-Full-Spec.md           authoritative product spec
│   ├── Stir-Cook-Mode-Architecture.md  voice implementation reference
│   ├── Gemini-Live-Findings.md     April 2026 spike + step-6 drift check
│   └── RevenueCat-Integration.md   ⚠ stale; refresh before step 5
└── Backend/
    └── supabase/
        ├── config.toml             local Supabase project config
        ├── .env.example            documents every secret the Edge Functions read
        ├── .env                    (gitignored) populated from `supabase status`
        ├── migrations/             11 SQL files: 7 tables, RLS, seeds, alias-forward fn
        ├── functions/
        │   ├── deno.json           shared compiler opts + import map
        │   ├── _shared/            10 typed helpers (auth, identity, gemini stub, …)
        │   ├── session-bootstrap/  POST /v1/session/bootstrap handler
        │   └── config-bootstrap/   GET  /v1/config/bootstrap handler
        └── tests/
            ├── _helpers/           env loader, factories, supabase clients
            ├── session_bootstrap_test.ts
            ├── config_bootstrap_test.ts
            ├── rls_isolation_test.ts
            └── auth_helpers_test.ts
```

---

## Prerequisites

| Tool | Minimum | Install |
| --- | --- | --- |
| Docker Desktop | running before `supabase start` | https://www.docker.com/products/docker-desktop |
| Supabase CLI | 2.0+ | `brew install supabase/tap/supabase` |
| Deno | 2.0+ | `brew install deno` |

The Edge Function runtime bundled inside Supabase uses Deno 2 internally. Tests run against your host's Deno. Both must be present.

---

## First-time setup

```bash
git clone <this-repo>
cd Stir/Backend/supabase
supabase start           # boots Postgres, PostgREST, Edge Runtime, etc. (~30s first time)
supabase db reset        # applies all 11 migrations from empty
```

Populate `.env` from the running stack so tests + functions serve can read the secrets:

```bash
# from Backend/supabase/
{
  URL=$(supabase status -o json | python3 -c "import json,sys; print(json.load(sys.stdin)['API_URL'])")
  ANON=$(supabase status -o json | python3 -c "import json,sys; print(json.load(sys.stdin)['ANON_KEY'])")
  SERVICE=$(supabase status -o json | python3 -c "import json,sys; print(json.load(sys.stdin)['SERVICE_ROLE_KEY'])")
  JWT_SECRET=$(supabase status -o json | python3 -c "import json,sys; print(json.load(sys.stdin)['JWT_SECRET'])")
  cat > .env <<EOF
SUPABASE_URL=$URL
SUPABASE_ANON_KEY=$ANON
SUPABASE_SERVICE_ROLE_KEY=$SERVICE
STIR_JWT_SECRET=$JWT_SECRET
GEMINI_API_KEY=placeholder-step-1-unused
EOF
}
```

`.env.example` documents the full shape and explains why the secret is named `STIR_JWT_SECRET` (Supabase filters `SUPABASE_*`-prefixed vars from `.env` at runtime; ours has to use a different name, but its value must equal the Supabase project's `jwt_secret` so PostgREST can validate our JWTs for RLS).

---

## Running the backend locally

```bash
# from Backend/supabase/
supabase functions serve --env-file .env
```

This serves both step-1 endpoints at:

- `POST http://127.0.0.1:54321/functions/v1/session-bootstrap`  →  spec `/v1/session/bootstrap`
- `GET  http://127.0.0.1:54321/functions/v1/config-bootstrap`   →  spec `/v1/config/bootstrap`

Smoke test:

```bash
INSTALL=$(uuidgen)
curl -s -X POST http://127.0.0.1:54321/functions/v1/session-bootstrap \
  -H 'content-type: application/json' \
  -d "{\"installation_id\":\"$INSTALL\",\"build\":\"1.0.0\",\"os_version\":\"17.5\"}" \
  | python3 -m json.tool
```

You should see a `session_jwt`, `canonical_user_key: "install:<UUID>"`, `is_new_user: true`, the full Round-3 entitlements object (Free tier, six dinner-solve cap, zero voice cap), and the eight server flags. Pass the `session_jwt` as a Bearer token to `config-bootstrap` for the same payload plus the seven default prompt rows.

---

## Running tests

```bash
# from Backend/supabase/, with `supabase start` AND `supabase functions serve` running
deno test --config=functions/deno.json --env-file=.env \
  --allow-env --allow-net --allow-read tests/
```

Expected: **36 passed | 0 failed**.

Coverage:

| File | What it asserts |
| --- | --- |
| `auth_helpers_test.ts` | JWT mint/verify round-trip, missing/malformed `Authorization`, deterministic canonical-key hashing, Zod rejection edges, `followMergedInto` one-hop-max invariant. In-process, no HTTP. |
| `session_bootstrap_test.ts` | install-only happy path, CloudKit-first happy path, alias-forward (install → ck row + counters merged), collision-without-cap-clamping, idempotent re-bootstrap, five VAL-01 rejection variants. |
| `config_bootstrap_test.ts` | happy path returns entitlements + 8 flags + 7 prompts; AUTH-01 with each of the four `reason` codes (`missing` / `malformed` / `expired` / `signature_invalid`); shape parity with bootstrap. |
| `rls_isolation_test.ts` | Two users, cross-user reads return **empty** (not 403) for `usage_counters`, `entitlement_snapshots`, `ai_request_log`, `device_installations`. The three ops-only tables (`app_users`, `feature_flags`, `prompt_versions`) return empty to any authenticated client. Service-role bypass sanity-checked. |

Test isolation strategy (per plan Round 3): every test generates fresh UUIDs; no teardown hooks, no transaction rollback. Run `supabase db reset` between test runs if accumulated rows become noisy in local dev — on a fresh Postgres it's sub-second.

---

## Deferred from step 1

These items are deliberately out of scope for the operational skeleton and will land in later steps. Captured here so they don't slip.

- **IP-based rate limiting on `/v1/session/bootstrap`** → step 3.
  Spec §13 calls for per-IP throttling to defend against the Apple-ID-rotation quota bypass. That attack surface doesn't exist until `/v1/ai/dinner-solve` lands in step 3, so the limiter ships there with a `rate_limit_buckets` table and a 30/day-per-IP sliding window. Supabase platform rate limiting is the backstop until then.

- **Gemini Live API drift re-check** → step 6 kickoff (cheap-half spike; ~1 hour curl + Deno).
  Distinct from the April 2026 full spike (which is done). See `Specs/Gemini-Live-Findings.md` for the specific endpoints + values to re-validate. Step 6 cannot start without this. Includes re-validating the `POST /v1alpha/authTokens` `400 INVALID_ARGUMENT` finding under the actual Edge Function environment; if it persists, fall back to OAuth service-account auth or backend-proxied WebSocket (both keep the Gemini key server-side).

- **`ops_flagged_outputs`, `audit_log`, `notification_jobs` tables** → step 8 (ops admin) and step 8 (push). Schema deliberately not added in step 1.

- **RevenueCat webhook handler + `entitlement_snapshots.raw_webhook_payload` writes** → step 5. The column exists in step 1 (NULL-default) so step 5 doesn't need an `ALTER TABLE`.

- **CI pipeline (GitHub Actions)** → step 8. Spec §13 describes the target shape (lint+tests on PR; `supabase db push` + `supabase functions deploy` to staging on `main`; tag promotion to prod; TestFlight via fastlane).

- **Refresh `Specs/RevenueCat-Integration.md`** → before step 5. The current doc describes a 2-product / single-`Stir Pro` entitlement model, which conflicts with the authoritative 4-SKU / Free-Premium-Pro model in `Specs/Stir-Full-Spec.md` + `CLAUDE.md`. Banner added at top of the file pending rewrite.

---

## Step-1 assumptions

These are the design calls made during step-1 build that aren't directly in the spec or main grill answers. Each is also tagged inline with `// ASSUMPTION:` in the source.

1. **"Unlimited" recipe imports modeled as `cap_count = 100_000`** (`functions/_shared/entitlements.ts` `TIER_CAPS`). Premium and Pro tiers nominally have unlimited imports per CLAUDE.md, but `usage_counters.cap_count` is `INTEGER NOT NULL` to keep the atomic UPDATE-WHERE-used<cap-RETURNING quota-check pattern uniform across all features. A literal `NULL` "unlimited" sentinel would force every quota check into a CASE expression. 100,000 is six orders of magnitude above any plausible monthly usage. Flag if wrong; alternative is `cap_count NULLABLE` + branched check.

2. **`period_start` uses the user's `app_users.created_at` day-of-month as the monthly anchor**, clamped to month length for short-month edges (Feb 29 → Feb 28). This matches Apple's subscription renewal pattern (no mid-month cliffs for new signups). Alternative would be calendar-month alignment (every period_start = 1st of month, UTC); rejected because it surprises new signups.

3. **Bootstrap is NOT wrapped in a single Postgres transaction.** Individual writes (`app_users` upsert, `device_installations` upsert, `entitlement_snapshots` upsert, `usage_counters` upsert, alias-forward RPC) are each idempotent via `ON CONFLICT DO NOTHING` or atomic UPSERT; partial failure on retry converges to the same state. Only the alias-forward step needs cross-table atomicity, and it's wrapped via the `stir_alias_forward` plpgsql function. A future step could promote the entire bootstrap to one RPC if observed races warrant.

4. **`feature_flags.rollout_pct` is stored but not enforced in step 1.** Rollout gating lands when the first prompt-version-keyed flag rolls out in step 3+. Step 1 returns the column as part of the wire shape so iOS can plumb it through.

5. **500-class internal errors return `NET-01`.** CLAUDE.md's matrix has no dedicated server-error code. NET-01 is closest in semantics ("Couldn't reach Stir right now" — server unreachable from the client's perspective is functionally equivalent to server-erroring). iOS retries on NET-01. If the distinction proves valuable, add a new `SRV-01` code via the matrix-update process.

6. **JWT `aud` is hardcoded to `"authenticated"`** in `_shared/auth.ts`. PostgREST's default `pgrst_jwt_aud` matches. If the Supabase project later configures a custom audience, update `issueSessionJWT` + `verifySessionJWT` together.

7. **Gemini client throws at call time, not at module load.** `_shared/gemini.ts` warns if `GEMINI_API_KEY` is missing at module load (so step-3+ misconfigurations show up in logs immediately) but only throws when `geminiGenerate()` or `geminiMintLiveAuthToken()` is actually invoked. Lets step-1 functions import the module without forcing a key requirement they don't yet need.

---

## Where to look next

- `CLAUDE.md` §"Build order" for the phased plan from here through beta.
- `Specs/Stir-Full-Spec.md` for product truth (north-star constraints, account states, AI architecture, billing, telemetry).
- `Backend/supabase/migrations/*.sql` for the operational schema, including comments documenting every non-obvious choice.
- `Backend/supabase/functions/_shared/` for the typed helper surface every later Edge Function will inherit.

When in doubt, the spec wins. Flag discrepancies between this README, `CLAUDE.md`, and the spec so one of them gets updated.
