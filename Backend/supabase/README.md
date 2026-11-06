# Backend/supabase — local dev + prod operator notes

Anything that exercises the Supabase stack — `supabase start`, `db reset`, `migration list`, `functions deploy`, `secrets set` — must run from this directory or with `--workdir Backend/supabase`. Otherwise the CLI silently shadows config and re-creates a stray `supabase/` at the repo root, which doesn't have the migrations or functions and produces confusing "no migrations found" errors.

> **TL;DR:** `cd Backend/supabase` before any `supabase` command. Run `cp .env functions/.env` once before the first `supabase start` of the day. Prod project ref is `ktqajarcomzplnpbczfo` — shell `$SUPABASE_URL` is MindFriend and is the wrong project. **Merging to `main` is the prod deploy; set new secrets first** (see [Deploy to prod](#deploy-to-prod)).

## Quick reference

```bash
cd Backend/supabase

# First-time-of-the-day setup (idempotent; safe to re-run)
cp .env functions/.env       # edge runtime loads secrets independently of Deno
supabase start               # boots Postgres + edge runtime + auth + storage

# Schema lifecycle
supabase db reset            # wipe + re-apply migrations + run seed.sql
supabase migration list      # local vs remote alignment

# Tests
deno test --config functions/deno.json --allow-all tests/

# Prod: merging to main deploys migrations + functions (see "Deploy to prod").
# Secrets are NOT deployed by that; set them first:
supabase secrets set KEY=value --project-ref ktqajarcomzplnpbczfo
```

## Deploy to prod

The Supabase GitHub integration deploys prod (`ktqajarcomzplnpbczfo`) on every push or merge to `main`, with working directory `Backend`. It applies new migrations and deploys every function declared in `config.toml`. It does **not** deploy secrets, API/Auth settings or seed files. Merging to `main` is therefore the prod deploy.

Order for a change that touches prod:

1. **Set new secrets before merging** code that reads them. The integration does not carry them over, and a function that reads a missing secret fails on its first request after the merge:

   ```bash
   cd Backend/supabase
   supabase secrets set ANTHROPIC_API_KEY=... OPENAI_API_KEY=... --project-ref ktqajarcomzplnpbczfo
   ```

   AI secrets (backend only, never on iOS): `ANTHROPIC_API_KEY` (Claude text), `OPENAI_API_KEY` (OpenAI Realtime client-secret mint), `GEMINI_API_KEY` (read only when `AI_TEXT_PROVIDER=gemini`), plus the existing secrets (`STIR_JWT_SECRET`, `REVENUECAT_WEBHOOK_SECRET`, the APNs tuple, `POSTHOG_API_KEY`, `SENTRY_DSN`, `LOG_IP_SALT`, `STIR_PGMQ_DISPATCH_SECRET`). `AI_TEXT_PROVIDER` (`anthropic` default | `gemini`) is optional; set it only to select Gemini for every text endpoint. Check what prod holds with `supabase secrets list --project-ref ktqajarcomzplnpbczfo`.
2. **Merge to `main`.** New migrations apply and every declared function deploys.
3. **Confirm alignment** (read-only): pin the project with `supabase link --project-ref ktqajarcomzplnpbczfo`, then `supabase migration list` should show matching local and remote columns.

Seed files, API settings and Auth settings are not covered by the integration; change those separately.

A manual `supabase functions deploy <name> --project-ref ktqajarcomzplnpbczfo` of a single function remains possible for a pre-merge smoke test. It puts the branch's code on prod immediately, so use it only for that, and set any secret the function reads first.

## Why the `cp .env functions/.env` step

The Supabase edge-runtime container loads its environment from `Backend/supabase/functions/.env`, **not** from `Backend/supabase/.env`. The Deno test runner reads `.env` (the parent), but edge functions running under `supabase functions serve` read `functions/.env` (the child). Without the copy, `supabase start` boots fine, but POSTing to any function returns a 500 on the first request that touches a `Deno.env.get(...)` call — typically `STIR_JWT_SECRET missing` since auth is the first thing every handler validates.

Two ways to handle:
- **Copy on each session start** (current convention): `cp .env functions/.env` before `supabase start`. Simple; explicit; avoids tooling-coupling magic.
- **`config.toml [edge_runtime.secrets]` block**: route both runtimes to the same env source. Worth doing once if a future contributor stumbles on this twice. Until then, the copy step is the documented path.

The `.env` and `functions/.env` files are both `.gitignore`d. They contain secrets that match the prod values (so handlers behave identically locally and in prod) — the local stack uses Supabase's local Postgres but the same Anthropic and OpenAI API keys, RevenueCat webhook secret, etc. (see `.env.example` for the key list; `AI_TEXT_PROVIDER` is optional and defaults to `anthropic`).

## Why `--workdir Backend/supabase` (or `cd` first)

`supabase` CLI looks for `supabase/config.toml` relative to the current working directory. If you run `supabase start` from the repo root, it discovers no config and boots a brand-new stack with zero migrations and zero functions. That stack lives at `<repo-root>/supabase/` (auto-generated, with stale `.branches/` and `.temp/` directories) and shadows the real `Backend/supabase/`.

If you ever see a fresh `supabase/` directory appear at the repo root, that's a sign someone (or some hook) ran `supabase` outside `Backend/supabase`. Delete the stray dir:

```bash
rm -rf <repo-root>/supabase
```

Nothing in it is git-tracked (the parent `.gitignore` covers `supabase/.temp/` and `supabase/.branches/`). Removing it is safe.

## Local vs prod project IDs

| | Project | Ref | Region |
|---|---|---|---|
| Local | `supabase_stir_local` (auto-generated) | `127.0.0.1:54321` | local Docker |
| **Prod** | **Stir** | **`ktqajarcomzplnpbczfo`** | West US (Oregon) |
| (Mistake to avoid) | MindFriend | `zfaucivtzfwnrijsbfug` | — |

Daniel's shell sometimes carries `SUPABASE_URL=https://zfaucivtzfwnrijsbfug.supabase.co` from MindFriend dev work. **That env var is wrong for Stir.** Always pin the project explicitly — `--project-ref ktqajarcomzplnpbczfo` on every `secrets` and manual `functions deploy` command, and `supabase link --project-ref ktqajarcomzplnpbczfo` before `migration list`. Otherwise prod work hits the wrong project and may corrupt MindFriend. The GitHub integration deploys to the right project on its own; the pin matters for the commands you run by hand.

`supabase migration list` should show local + remote columns matching once linked and after the merge to `main` has deployed. Before the merge, a migration that exists only locally is expected.

## Pre-push gate ergonomics

The repo's pre-push hook (`scripts/git-hooks/pre-push`) runs `deno test ... tests/` against `localhost:54321`. If the local stack isn't running, the deno stage warn-skips. To gate properly:

```bash
cd Backend/supabase
supabase start
# ... do work ...
git push                # pre-push runs xcodebuild + deno tests
```

The hook does NOT auto-start the stack. Override patterns documented in `scripts/git-hooks/pre-push`:
- `SKIP_PREPUSH_TESTS=1 SKIP_PREPUSH_REASON='…' git push` — skips both stages
- `SKIP_PREPUSH_DENO_TESTS=1 git push` — skips deno only

## Common gotchas

| Symptom | Cause | Fix |
|---|---|---|
| `STIR_JWT_SECRET missing` on first request after `supabase start` | `.env` not copied to `functions/.env` | `cp Backend/supabase/.env Backend/supabase/functions/.env` then restart the stack |
| `no migrations found` despite migrations existing | Ran `supabase` from repo root | `cd Backend/supabase` and re-run; delete the auto-generated `<repo-root>/supabase/` |
| `supabase migration list` shows local-only migrations | Not linked to prod, OR linked to wrong project, OR the change has not been merged to `main` yet (migrations apply on merge) | `supabase link --project-ref ktqajarcomzplnpbczfo`; merge if the change is ready |
| Migration apply errors on enum / constraint conflicts | Prod is ahead of local — something was applied to prod outside `main` | `supabase db pull` and reconcile with a forward migration before merging |
| A function fails on its first prod request after a merge with a missing-key error (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`) | The GitHub integration does not deploy secrets and the secret was not set before the merge | `supabase secrets set KEY=value --project-ref ktqajarcomzplnpbczfo`, then re-test |
| Every text call fails with `AI_TEXT_PROVIDER must be 'anthropic' or 'gemini'` | The `AI_TEXT_PROVIDER` secret holds a typo (an unrecognized value throws rather than picking a provider) | Set it to `anthropic` or `gemini`, or unset it for the `anthropic` default |
| Deno tests pass locally, fail in pre-push | Edge runtime is using the main checkout's mount, not your worktree | See `docs/runbooks/isolated-worktree-verification.md` |

## Provenance

- Linear: SCA-141 (parent SCA-58)
- `docs/deferred-work.md` line 147 — original trigger entry
- CLAUDE.md §Deploy workflow — prod project ref
- `docs/decisions/0038-ai-provider-claude-text-openai-voice.md` — AI providers and the secrets they need
- `docs/runbooks/isolated-worktree-verification.md` — multi-worktree edge-runtime mount strategy
