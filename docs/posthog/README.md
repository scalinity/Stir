# PostHog dashboards

`dashboards.json` contains the insight blueprints for the 7 core Stir dashboards named in spec §15. PostHog's UI-based import doesn't accept this format natively; use it as a checklist + copy-paste source.

## Import procedure

1. Sign in to PostHog (project: Stir).
2. Create each dashboard manually using the structure in `dashboards.json`:
   - For funnels: Insights → New → Funnel → add steps matching the `steps` array.
   - For retention: Insights → New → Retention → target/return events from the JSON.
   - For aggregated insights: Insights → New → Trend → set aggregation + breakdown keys.
3. Save each insight to the corresponding dashboard.

## Event property references

Every event name + property referenced in `dashboards.json` MUST appear in:
- Spec §15 event table (product events like `scan_submitted`, `voice_affordance_tapped`), OR
- Spec §15 `$ai_generation` / `$ai_trace` property table (LLM Observability events).

If a referenced property doesn't exist yet on PostHog (telemetry code not yet emitting it), the insight shows "no data" silently. This is intentional — the JSON acts as both import source + telemetry-coverage gap detector.

## Updating

- Add a new event → update spec §15 + CLAUDE.md §Telemetry events + add a tile to `dashboards.json` in the same commit.
- Remove an event → same reverse flow.

Source-of-truth divergence is the single biggest ops-telemetry footgun. Keep the three (spec §15, CLAUDE.md, dashboards.json) synced commit-by-commit.
