# Legal Pages Publish Runbook

**Owner:** Daniel
**Targets:** https://getstir.app/terms and https://getstir.app/privacy
**Sources:** `docs/legal/terms-of-service.md` + `docs/legal/privacy-policy.md`

The .md files in `docs/legal/` are repository-tracked drafts that include internal-only sections (DRAFT markers, `[LEGAL REVIEW REQUIRED]` placeholders, lawyer-review checklists, internal cross-references). The published HTML versions hosted at `getstir.app/{terms,privacy}` MUST strip those sections before going live.

## Pre-publish strip checklist

For each `.md` source file, the publish pipeline (or manual hand-conversion to HTML) MUST remove:

1. **The DRAFT header block at the top** — anything between the H1 `# Stir — Terms of Service` (or `# Stir — Privacy Policy`) and the `**Last updated:**` / `**Effective:**` lines is internal status metadata. The `**Status:** DRAFT — pending lawyer review.` line MUST NOT appear in the published version.
2. **All `[LEGAL REVIEW REQUIRED — *]` tokens** — none should remain in the published copy. Grep:
   ```bash
   grep -n "\[LEGAL REVIEW REQUIRED" docs/legal/{terms-of-service,privacy-policy}.md
   ```
   Any hit is a publish blocker. Replace with the lawyer-finalized text or remove the surrounding clause.
3. **The `## Lawyer review checklist (DRAFT signal — remove before publish)` section** at the bottom of both files — and everything below it. Search for the literal string `Lawyer review checklist (DRAFT signal — remove before publish)` and truncate the file at that line.
4. **The `## Internal cross-references` section** — references to internal repo paths (`docs/runbooks/...`, `Specs/Stir-Full-Spec.md`, etc.) confirm internal layout publicly. Truncate.
5. **The `---` horizontal rule preceding the lawyer-review block** — typically the last `---` in the file. Truncate at this line.

The truncation point in both files is the second-to-last `---` rule (the one immediately before the lawyer-review block).

## Publish steps

1. **Lawyer sign-off** on the .md content (everything ABOVE the truncation point above). Materially modified text from the lawyer must be merged back into the .md sources via PR before this step proceeds.
2. **Strip** per the checklist above. Output: clean .md ready for HTML conversion.
3. **HTML conversion** — preserve heading hierarchy, list formatting, and table rendering. Recommended converter: Pandoc with default GitHub-flavored markdown settings (`pandoc -f gfm -t html5`).
4. **Verify** the rendered HTML:
   - No DRAFT/`[LEGAL REVIEW REQUIRED]`/lawyer-checklist text visible.
   - No `docs/`, `Specs/`, or other internal paths visible.
   - All hyperlinks (privacy@getstir.app, support@getstir.app, App Store link, Apple subscription path) resolve correctly.
5. **Deploy** to https://getstir.app/{terms,privacy}. Both pages MUST return HTTP 200 before the next iOS build is uploaded to TestFlight. The iOS paywall and Settings deep-link to these URLs (`PaywallView.swift`, `SettingsRootView.swift`).
6. **Smoke test** by curling both URLs and grepping for residual DRAFT markers:
   ```bash
   curl -s https://getstir.app/terms | grep -i "DRAFT\|LEGAL REVIEW REQUIRED" || echo "clean"
   curl -s https://getstir.app/privacy | grep -i "DRAFT\|LEGAL REVIEW REQUIRED" || echo "clean"
   ```
   Both MUST print "clean".

## Update cadence

Re-run this runbook on every material policy change:
- Subprocessor added/removed
- Retention window changed (after backend cron-purge work lands per CLAUDE.md §Deferred entry "Backend retention crons for ai_request_log…")
- New CCPA disclosure or California law update
- New trial / pricing terms (paywall disclosure section)
- Operator legal entity finalized (replace the "Operator, identified at https://getstir.app/about" reference in ToS §10 with the entity name)

## Rollback

If a publish ships with residual DRAFT content (caught in step 6 verify or by user report):
1. **Immediate:** revert to prior published HTML.
2. **Within 24h:** scrubbed re-publish following this runbook.
3. **Post-mortem:** add the missed strip target to step 2 of this runbook so the next publish doesn't recur.

## Pre-existing drift notes

Until the lawyer-finalized version of the ToS is signed and the entity name is published at `https://getstir.app/about`, the ToS §10 references "the operator of the Stir service" rather than naming a specific legal entity. This wording is correct as published; once the entity is finalized, update both the .md source AND the `https://getstir.app/about` page in the same PR.
