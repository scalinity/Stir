# Stir — Architecture Decision Records

This directory is the historical record of material architectural choices. Claude Code reads it. Future-Daniel reads it. Together, they decide whether a past decision still holds.

## What belongs here

An ADR captures a decision that would cost time to re-derive. Write one when:

1. **A load-bearing choice is made** — stack selection, data-model boundary, security posture, SKU economics, auth model.
2. **A reasonable alternative was rejected** — document both the choice AND the runners-up, so a future revisit doesn't re-discover the same tradeoffs.
3. **A spec / CLAUDE.md rule gets added or retired** — the "why" lives here; the "what" stays in the spec.
4. **A deferred fix is accepted** — note the deferral, the trigger that reopens it, and who owns it.

An ADR does NOT belong here for:

- Day-to-day implementation choices (pick a library, name a function).
- Things fully captured by the code itself (struct shape, enum values).
- Bug fixes — those go in commits with reasoning.

**Rule of thumb:** if a future engineer reading the code alone would arrive at the same answer, no ADR needed. If they'd need to read meeting notes, conversation history, or re-run a cost model — write the ADR.

## File naming

```
NNNN-kebab-short-name.md
```

Where `NNNN` is a zero-padded sequential number. Never recycle numbers; never renumber existing ADRs. Superseded ADRs stay in place and link forward.

## Template

Copy `TEMPLATE.md`. Fill in every section. Keep prose tight — ADRs should be readable in under five minutes.

## Statuses

- **Proposed** — drafted but not yet committed to code.
- **Accepted** — in effect; code reflects it.
- **Deferred** — accepted in principle but work hasn't happened yet. Include a trigger and an owner-step.
- **Superseded by NNNN** — replaced; link forward. Do not delete.
- **Rejected** — considered and declined. Kept so the same idea doesn't come back unexamined.

## When Claude works on a decision

When user or context indicates a decision-worthy moment, Claude must:

1. Check this directory for a prior ADR on the topic.
2. If one exists and is Accepted/Deferred, follow it. Flag if user wants to revisit.
3. If the current work represents a new decision, create an ADR before (or alongside) the code change. Do NOT land a load-bearing choice without the ADR.
4. If code diverges from an Accepted ADR, either amend the ADR or revert the code. Silent divergence is banned.

## Index

| # | Title | Status | Relates to |
|---|-------|--------|------------|
| [0001](./0001-decisions-system.md) | Decisions system (this directory) | Accepted | CLAUDE.md §Decisions system |
| [0002](./0002-design-system-deferred.md) | Design system deferred; generic SwiftUI accepted through v1 beta | Deferred | FD1 review findings, step 9 beta |
| [0003](./0003-revenuecat-shared-secret-auth.md) | RevenueCat webhook uses shared-secret `Authorization` header, not HMAC | Accepted | webhook handler, SA2 review |
| [0004](./0004-supabase-entitlement-source-of-truth.md) | Supabase entitlement_snapshots is source of truth; RC is a refresh trigger only | Accepted | Billing model, CLAUDE.md §Billing |
| [0005](./0005-alias-forward-promote-entitlement.md) | stir_alias_forward promotes install→ck entitlement when ck has no row | Accepted | Migration 20260419000004 |
