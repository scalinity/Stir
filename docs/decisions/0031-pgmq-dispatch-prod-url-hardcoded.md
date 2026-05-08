# ADR 0031: pgmq-dispatch prod URL hardcoded in migration; manual trigger restricted to literal on prod

- **Status**: Accepted
- **Date**: 2026-05-07
- **Owner-step**: Step 9 (ops hardening) — revisit when SCA-157 lands
- **Related**: SCA-85, SCA-157, migrations `20260419000014_schedule_pgmq_dispatch.sql`, `20260504000001_pgmq_dispatch_shared_secret.sql`, `20260508000003_pgmq_dispatch_register_hardcoded_url.sql`, `20260508000004_pgmq_dispatch_cron_secret_header.sql`. CLAUDE.md §Deploy workflow.

## Context

Two prior migrations registered the `stir-pgmq-dispatch` cron via `current_setting('app.supabase_url', TRUE)` and gracefully early-returned when the GUC was unset. The Supabase managed-postgres role can't `ALTER DATABASE postgres SET "app.supabase_url" = ...` (ERROR 42501 — only the platform's superuser can grant settability for the `app.*` GUC class). Prod silently shipped with the cron unregistered, and every push notification path (reactivation, billing-grace, leftovers-followup, use-soon, recipe-import-async) was a no-op because the queue never drained.

Verifying SCA-63's prod deploy surfaced this. The fix needed to register the cron without depending on a GUC the platform won't let us set.

## Decision

Hardcode the prod project URL (`https://ktqajarcomzplnpbczfo.supabase.co/functions/v1/pgmq-dispatch`) into the migration that registers the cron. Gate the registration on `current_database() = 'postgres'` so local dev / preview branches keep their existing GUC-driven path. Tighten `stir_pgmq_dispatch_trigger_once` to the same literal-on-prod posture so cron and manual paths can never split-brain.

## Alternatives considered

- **Continue with the GUC pattern** — Rejected. The platform refuses the `ALTER DATABASE` call (`42501`) and supplying the value via `SET LOCAL` from a future role-relaxed function is the SSRF-shaped attack surface SA1-M2 called out. The pattern is structurally unviable on managed Supabase.

- **Use `vault.decrypted_secrets` as the URL store** — Rejected for v1 because the URL is public information (Supabase project URLs are discoverable via DNS / admin UI), so storing it in Vault adds operational ceremony without privacy benefit. Vault is the correct path for the *secret* (`STIR_PGMQ_DISPATCH_SECRET` — see SCA-157), not the URL.

- **Read the URL from a Supabase Edge Function env var via `pg_net`'s plpgsql wrapper** — Rejected. Edge Function env vars aren't reachable from Postgres without a round-trip; if Postgres can hit an Edge Function to ask for the URL, it can already hit the dispatcher directly.

- **Move the cron registration into the Edge Function itself (self-register on first invocation)** — Rejected. Adds a per-cold-start race against the cron schedule; doesn't compose with the migration-as-deploy-artifact model the rest of the backend uses.

## Consequences

### Positive

- Prod cron registration is deterministic and survives every `db push`.
- Single source of truth for the dispatcher URL — no GUC drift between local + remote.
- The literal URL is greppable; future ops can find every reference in a single search.
- Mirrors the (correct) pattern Supabase's own templates use for project-pinned resources (e.g., realtime channels, storage buckets).

### Negative

- A second prod project (e.g., a stir-eu deployment) requires a new migration with its own URL literal. The migration is small and the cost is bounded — but it's not configuration, it's code.
- Local dev path and prod path now have asymmetric registration logic (GUC-driven on local via `20260419000014` / `20260504000001`; literal on prod via `20260508000003` / `20260508000004`). Future changes to either path need to think about both.

### Tradeoffs

- Hardcoding sits poorly with the "configuration over code" principle, but the GUC alternative is structurally blocked by managed-platform constraints. The literal path is honest about what it is.

## Trigger to revisit (Deferred only)

When **SCA-157** moves `STIR_PGMQ_DISPATCH_SECRET` from the `app.stir_pgmq_dispatch_secret` GUC to `vault.decrypted_secrets`. At that point:

1. Re-evaluate whether the URL itself should also live in Vault (probably not — still public info).
2. If a second prod project is on the roadmap, take that as the trigger to introduce a `stir_config` table or equivalent runtime-config primitive.
3. If neither has happened, this ADR stays Accepted indefinitely — the literal URL is fine forever for a single-project deployment.

Until then, any new migration that needs the dispatcher URL must:
- Use the literal `https://ktqajarcomzplnpbczfo.supabase.co/functions/v1/pgmq-dispatch` for prod
- Gate the literal path on `current_database() = 'postgres'`
- Document the asymmetry in the migration header
