# Backend/supabase — local dev + prod operator notes

Anything that exercises the Supabase stack — `supabase start`, `db reset`, `migration list`, `db push`, `functions deploy`, `secrets set` — must run from this directory or with `--workdir Backend/supabase`. Otherwise the CLI silently shadows config and re-creates a stray `supabase/` at the repo root, which doesn't have the migrations or functions and produces confusing "no migrations found" errors.

> **TL;DR:** `cd Backend/supabase` before any `supabase` command. Run `cp .env functions/.env` once before the first `supabase start` of the day. Prod project ref is `ktqajarcomzplnpbczfo` — shell `$SUPABASE_URL` is MindFriend and is the wrong project.

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

# Deploy to prod (lockstep — see CLAUDE.md §Deploy workflow)
supabase link --project-ref ktqajarcomzplnpbczfo  # MUST pin before db push
supabase db push
supabase functions deploy <name>
supabase secrets set KEY=value --project-ref ktqajarcomzplnpbczfo
```

## Why the `cp .env functions/.env` step

The Supabase edge-runtime container loads its environment from `Backend/supabase/functions/.env`, **not** from `Backend/supabase/.env`. The Deno test runner reads `.env` (the parent), but edge functions running under `supabase functions serve` read `functions/.env` (the child). Without the copy, `supabase start` boots fine, but POSTing to any function returns a 500 on the first request that touches a `Deno.env.get(...)` call — typically `STIR_JWT_SECRET missing` since auth is the first thing every handler validates.

Two ways to handle:
- **Copy on each session start** (current convention): `cp .env functions/.env` before `supabase start`. Simple; explicit; avoids tooling-coupling magic.
- **`config.toml [edge_runtime.secrets]` block**: route both runtimes to the same env source. Worth doing once if a future contributor stumbles on this twice. Until then, the copy step is the documented path.

The `.env` and `functions/.env` files are both `.gitignore`d. They contain secrets that match the prod values (so handlers behave identically locally and in prod) — the local stack uses Supabase's local Postgres but the same Gemini API key, RevenueCat webhook secret, etc. (see `.env.example` for the full key list).

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

Daniel's shell sometimes carries `SUPABASE_URL=https://zfaucivtzfwnrijsbfug.supabase.co` from MindFriend dev work. **That env var is wrong for Stir.** Always pin the project explicitly via `supabase link --project-ref ktqajarcomzplnpbczfo` before any `db push`, `functions deploy`, or `secrets` command. Otherwise prod work hits the wrong project and may corrupt MindFriend.

`supabase migration list` should show local + remote columns matching once linked. If they don't align, see CLAUDE.md §Deploy workflow before running `db push`.

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
| `supabase migration list` shows local-only migrations | Not linked to prod, OR linked to wrong project | `supabase link --project-ref ktqajarcomzplnpbczfo` |
| `db push` errors on enum / constraint conflicts | Prod is ahead of local — someone else pushed since you last synced | `supabase db pull` and reconcile before re-pushing |
| Deno tests pass locally, fail in pre-push | Edge runtime is using the main checkout's mount, not your worktree | See `docs/runbooks/isolated-worktree-verification.md` |

## Provenance

- Linear: SCA-141 (parent SCA-58)
- `docs/deferred-work.md` line 147 — original trigger entry
- CLAUDE.md §Deploy workflow — prod project ref + lockstep deploy rules
- `docs/runbooks/isolated-worktree-verification.md` — multi-worktree edge-runtime mount strategy
