# ADR 0024: Ops SPA runs from Vite dev server in step 8 / deploys via Edge Function + Supabase Storage in step 9

- **Status**: Accepted (step 8 local-only portion) / Deferred (step 9 deploy)
- **Date**: 2026-04-24
- **Owner-step**: Step 8 (local dev) / Step 9 (prod deploy)
- **Related**: Spec §14 Admin & Ops Tooling; `ops/` SPA (step 8 Phase 8); ADR 0023 admin auth

## Context

Step 8 Phase 8 ships a React SPA (`ops/`) that an admin opens on their laptop to run user lookups, quota resets, flagged-output reviews, prompt rollouts, and feature-flag toggles. The SPA has no build artifacts deployed anywhere yet — Phase 8 Daniel-kickoff asked for "served from Supabase Edge Function with static assets in Supabase Storage bucket" as the default but left the deploy decision open.

Two real options:

- **Edge Function + Supabase Storage** — `ops-ui` Edge Function serves `index.html` + routes `GET /assets/*` to a public `ops-spa` Storage bucket. Single-origin with Supabase Auth, no CORS config, one less vendor.
- **Vercel / Netlify** — static hosting, instant deploys, preview per PR. Adds a vendor + requires Supabase Auth CORS allowlist for the new origin.

Step 8 demo needs to work TODAY (admin login → cost view → flag resolve); step 9 needs a hosted URL for routine ops use.

## Decision

**Step 8:** Ops SPA runs via `npm run dev` against the prod Supabase URL. Admin opens `localhost:5173` in their browser. Magic link signs them in; the Supabase session persists via localStorage; all 4 demo bullets pass without any hosted artifact.

**Step 9:** Deploy via `ops-ui` Edge Function + `ops-spa` Supabase Storage bucket (public-read, admin-bucket-write). Deploy flow:

1. `cd ops && npm run build` → `ops/dist/`
2. `supabase storage upload` (or `deploy.sh` script) syncs `dist/` → `ops-spa` bucket
3. `supabase functions deploy ops-ui` reads from bucket on request, serves files with appropriate `content-type` + `cache-control`

Magic-link redirect URLs — admin updates Supabase Auth config in the dashboard to allow both `http://localhost:5173` (local dev) and `https://<project>.supabase.co/functions/v1/ops-ui` (prod) — this is the only manual config step.

## Alternatives considered

- **Vercel / Netlify** — rejected for step 9: adds a vendor Stir doesn't otherwise use, requires CORS allowlisting on Supabase Auth + on the `/v1/ops/admin` Edge Function, and gives us preview deploys we don't need (the SPA has no production release discipline — it's internal tooling).
- **Serve SPA bundle inline from the ops-ui Edge Function (no Storage)** — rejected: bundle is 285 kB gzipped 86 kB; embedding as a string in TS would slow cold-starts and make every code deploy re-upload the same static assets.
- **Public S3 / CloudFront** — rejected: external dependency for a 1-person-admin console is overkill.

## Consequences

### Positive
- Step 8 demo is unblocked — no hosting work required to run the full 4-bullet demo.
- Step 9 hosting stays inside Supabase; single auth domain avoids CORS.
- Bundle lives in Storage; deploying just the Edge Function (no bundle change) is fast.
- No new vendor.

### Negative
- Manual deploy step in step 9 until a GitHub Actions workflow exists.
- No preview deploys — a regression in the SPA is caught when Daniel refreshes the page, not when a PR lands. Acceptable for internal tooling.

### Tradeoffs
- We pay the "manual build-and-upload" cost for simplicity. If admin count grows past 5 and iteration velocity matters, revisit with Vercel.

## Trigger to revisit (Deferred portion)

Admin count > 5 OR ops SPA iteration rate exceeds ~1 deploy/week — move to a hosting solution with preview deploys.

## Notes

- `.env.example` documents the two required Vite env vars: `VITE_SUPABASE_URL` + `VITE_SUPABASE_ANON_KEY`. Local `.env.local` is gitignored.
- `ops/README.md` contains the local-run instructions. Step 9 runbook (`docs/runbooks/ops-spa-deploy.md`) will add the storage-upload + edge-deploy flow.
- 4 of 8 pages shipped functional in step 8; 4 scaffolded as "deferred to step-9 polish" (Voice Sessions, Feature Flags, Prompt Versions, Audit Log) with backend actions already available via `/v1/ops/admin`.
