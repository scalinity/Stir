# ADR 0025: Eval harness structure — `Backend/evals/<feature>/` + shared infra + `STIR_RUN_AI_EVALS=1` gate; corpus buildout deferred to step 9 prerequisite

- **Status**: Accepted (infra) / Deferred (corpus)
- **Date**: 2026-04-24
- **Owner-step**: Step 8 (infra) / Step 9 (corpus curation, blocks TestFlight)
- **Related**: Spec §16 Testing Strategy / AI eval set; `Backend/evals/` (step 8 Phase 6); CLAUDE.md §Verification flows; ADR 0023 admin auth (unrelated but same step)

## Context

Spec §16 commits to six eval sets with specific case counts + pass criteria:

| Eval set                |          Size | Pass criteria                        |
| ----------------------- | ------------: | ------------------------------------ |
| `eval_pantry_scan_v1`   |    150 photos | precision ≥ 0.90, recall ≥ 0.75      |
| `eval_dinner_solve_v1`  | 200 scenarios | 100% hard-rule pass, 85% cookability |
| `eval_cook_turns_v1`    |     300 turns | wrong-step rate < 3%; preamble ≥ 95% |
| `eval_substitutions_v1` |     300 cases | 100% hard-rule pass (0 allergen)     |
| `eval_recipe_import_v1` |   100 recipes | 85% acceptable without major edit    |
| `eval_grocery_v1`       |     100 plans | 98% missing-item recall              |

Step 8 Phase 6 ships the HARNESS INFRASTRUCTURE that runs these. The actual corpora are hand-curated content (real kitchen photos, scripted voice dialogs, synthetic-but-validated substitution cases) — curation cost is ~8–12 hours of Daniel-time per corpus. Shipping empty-case infrastructure in step 8 + full corpora in step 9 prereq is strictly faster than trying to do both in one pass.

Daniel's D9 decision in the step-8 kickoff:
> B. Harness now, corpora in step 9. Evals are infra-only; step 9 TestFlight blocked on corpus.

## Decision

Layer structure:

```
Backend/evals/
  _shared/
    harness.ts       — HarnessResult interface + gateOrSkip(name) helper
    junit.ts         — <testsuites><testsuite><testcase> XML writer
    report.ts        — ANSI color console report
    corpus_loader.ts — JSONL loader + optional zod validation
  <feature>/
    run.ts           — exports runHarness(): Promise<HarnessResult>
    eval_<feature>_v1.jsonl   — corpus (added step 9)
    fixtures/                 — binary assets (photos), when needed
  run_all.ts         — orchestrator; imports all 6 harnesses; --junit + --only flags
```

Gating:
- `STIR_RUN_AI_EVALS=1` environment variable required to run. Absent → every harness returns `{ skipped: true, skip_reason: 'STIR_RUN_AI_EVALS=1 not set — refusing to burn Gemini credits' }` and `run_all.ts` exits 0. Prevents accidental Gemini spend on CI / dev invocations.
- `--budget-usd <N>` flag (reserved, not yet wired): orchestrator-level hard ceiling. Planned for step 9 when real corpora run.

Per-harness `HarnessResult`:
- `pass: boolean` — true iff every criterion passed
- `criteria: Array<{ name, pass, actual, threshold, unit? }>` — one row per spec §16 threshold
- `cases_total` / `cases_passed` / `failures[]` — per-case drill-down
- `duration_ms` + `cost_usd` — run-level metrics
- `skipped?: true` + `skip_reason?: string` — distinct from a genuine fail

JUnit XML output: one `<testcase>` per criterion inside one `<testsuite>` per harness. Compatible with GitHub Actions annotation renderers.

package.json scripts:
- `eval:pantry-scan`, `eval:dinner-solve`, `eval:cook-turns`, `eval:substitutions`, `eval:recipe-import`, `eval:grocery` — per-harness invocations
- `eval:all` — `run_all.ts` orchestrator with optional `--junit <path>` + `--only a,b,c`

## Alternatives considered

- **Mega-script approach** — one giant `eval.ts` with switch on feature. Rejected: different corpora have different parsing + assertion shapes (image files vs JSONL cases vs audio dialogs); one file would be ~2 kLoC of branches.
- **Ship full corpora in step 8** — rejected per D9. Would extend step 8 by ~1–2 weeks of Daniel curation work, delaying TestFlight beta (step 9) for content that belongs with the step-9 beta-readiness pass anyway.
- **Drop the gate, trust developers not to burn credits** — rejected. `pnpm run eval:substitutions` has ~300 Gemini calls ≈ $0.90; running accidentally in a CI environment loop would burn fast.

## Consequences

### Positive
- Infrastructure is stable + tested in step 8 (7 unit tests across _shared).
- Corpus curation is parallelizable — Daniel can build one corpus at a time between step 8 and step 9.
- JUnit XML hooks into any standard CI provider (spec §16 wants pre-merge-on-prompt-change runs; step 9 wires the GitHub Action).
- `{ skipped: true }` return shape means `run_all.ts` succeeds in CI without STIR_RUN_AI_EVALS=1 — no flaky "partially configured" runs.

### Negative
- Step 8 eval:all prints "5 skipped" for the new harnesses + one genuine substitutions run (if credits allowed). No real quality gate until step 9.
- `substitutions` harness (step 4) does NOT yet export `runHarness(): HarnessResult` — it has its own console output + exit code. `run_all.ts` excludes it; `pnpm run eval:substitutions` runs it standalone. Unification tracked below.

### Tradeoffs
- We accept "infrastructure precedes content" for two phases. Payoff: when step 9 corpora land they plug into a already-tested infra layer.

## Trigger to revisit (Deferred corpus portion)

- Step 9 TestFlight submission date: full corpora MUST pass their thresholds before the TestFlight build is cut. This is the non-negotiable gate.
- Cost ceiling: `pnpm run eval:all` with full corpora is projected at ~$3-5 per run. If observed >$10, add the `--budget-usd` ceiling enforcement.

## Notes

- **substitutions harness unification**: step 4's `Backend/evals/substitutions/run.ts` uses step-4-shaped IO (console output + exit code on allergen failures). Refactoring to match the step-8 `HarnessResult` contract is a small lift (wrap the existing `report()` output + return a populated `HarnessResult`) but was out of step 8's scope. Track: next substantive edit to substitutions/run.ts should include the wrap.
- **Corpus curation ownership**: Daniel curates between step 8 land and step 9 kickoff. ~8–12h per corpus × 6 corpora = ~48–72h total; realistically parallel with other step-9 beta prep work.
- **Synthetic-to-validated pipeline**: Gemini 3 Pro generates candidate cases per spec §16 guidance; Daniel validates by hand. No Gemini-generated case ships as ground truth without human confirmation.
- **Allergen-heavy substitution weighting**: spec §16 explicitly calls out peanut / tree nut / dairy / gluten / egg / shellfish / soy as priorities. Corpus curation must not regress below 150/300 allergen-adjacent cases.
