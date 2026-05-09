# Stir migrations — local discipline

This README documents the conventions Stir migrations follow on top of Supabase's defaults. Read `CLAUDE.md` §"Schema truth" + §"Immutable-migration policy" first; this file is a quick reference, not the authoritative source.

## Naming

```
YYYYMMDDHHMMSS_kebab-short-description.sql
```

The leading 14-digit timestamp determines apply order. Supabase CLI sorts lexicographically, so leading-zero-padded timestamps are mandatory.

## SCA-268 — Unique-per-second discipline

Two migrations on `2026-05-08` share the prefix `20260508000008_*`:

- `20260508000008_deletion_request_sla_alerts.sql`
- `20260508000008_drop_deletion_requests_completed_at.sql`

They are **commutative** today (different surfaces — one creates a function, the other drops a column), so application order doesn't matter. But the same-second collision is fragile: if a future maintainer renames either file for cosmetic reasons (typo, kebab-case style), the lexical order between them flips silently and a fresh `supabase db reset` could apply them in a new order.

**Going forward** (filed as SCA-268, S2 from /review-5): every new migration MUST land at a timestamp at least one second past the previous migration. Use `date -u +%Y%m%d%H%M%S` immediately before staging the new file. If two ticket trains are landing on the same day, the second one bumps to the next free second — even if the body would have been valid at the same timestamp.

The two existing collision pairs (`20260508000006_*`, `20260508000007_*`, `20260508000008_*`) are NOT being renamed because:

1. The immutable-migration policy in CLAUDE.md forbids cosmetic edits to applied migrations.
2. All three pairs are commutative; lexical order between them doesn't affect any existing environment.
3. A renamed file applied to a fresh dev environment would create a phantom "new migration" record that doesn't match any prod state.

If a future need to physically separate one of the pairs arises, the correct path is a security-fix-style supersession (per CLAUDE.md), not an in-place rename.

## See also

- `CLAUDE.md` §"Schema truth" — column-type retcons, CHECK constraints worth knowing.
- `CLAUDE.md` §"Immutable-migration policy" — the rules for when a file may be edited (security-fix exception only).
- `docs/runbooks/supabase-migration-reconciliation.md` — what to do when local and prod migration tables drift.
