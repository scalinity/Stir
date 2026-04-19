# ADR 0001: Decisions system

- **Status**: Accepted
- **Date**: 2026-04-19
- **Owner-step**: standing
- **Related**: CLAUDE.md §Decisions system, `docs/decisions/README.md`

## Context

Stir is being built in phased steps (1–9). Past-Claude made load-bearing decisions in conversations that don't live anywhere discoverable after the conversation ends — RC auth model choice, alias-forward behavior, single-vendor AI, SKU economics, etc. Some landed in CLAUDE.md's "What NOT to reopen" list, some in spec sections, but the *reasoning* (alternatives, tradeoffs, rejection grounds) got lost. Future-Claude and future-Daniel need a searchable, durable record to avoid re-litigating settled matters or, worse, silently reversing them.

## Decision

Adopt ADRs (Architecture Decision Records) in `docs/decisions/`. One file per decision. Sequentially numbered. Every load-bearing architectural choice — including choices to *defer* work — gets an ADR. CLAUDE.md's "What NOT to reopen" section links to ADRs for the authoritative reasoning; the list itself remains the quick-reference TL;DR.

## Alternatives considered

- **GitHub issues with a `decision` label** — rejected: tied to remote infrastructure, harder to read offline, bad fit for Claude's file-reading workflow.
- **In-CLAUDE.md prose** — rejected: CLAUDE.md is already ~800 lines; adding multi-section explanations per decision dilutes the cache-first role it plays.
- **ADRs inside a `decisions.md` single file** — rejected: loses addressability; ADR numbers in commit messages / code comments need to resolve to stable URLs / paths.

## Consequences

### Positive

- Every material decision has a stable anchor (file path, number).
- Deferred work has an explicit trigger — no more "we'll get to it eventually" rot.
- Future sessions can search `docs/decisions/` and get context in seconds.
- Rejected alternatives stay visible so the same idea doesn't cycle back unexamined.

### Negative

- Discipline cost: every new load-bearing choice needs an ADR written. Missing ADRs are silent until a future conflict exposes them.
- Synchronization cost: CLAUDE.md "What NOT to reopen" and spec sections must reference ADRs. Drift between the three is a real risk.

### Tradeoffs

- Process weight in exchange for memory durability. For a solo-builder, the per-decision overhead is 5–10 minutes; the benefit compounds over years of the project's life.

## Notes

- Numbering is sequential, zero-padded to 4 digits. Never recycle.
- Superseded ADRs are NOT deleted; they get a `Superseded by NNNN` header and stay in place.
- CLAUDE.md §"Decisions system" (added in the same commit as this ADR) codifies when Claude must create one.
