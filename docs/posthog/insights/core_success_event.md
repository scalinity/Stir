# PostHog insight — `core_success_event` funnel

**Definition (CLAUDE.md §Telemetry anchors):** scan → select → cook within
3 min → rate ≥4.

This funnel measures the end-to-end "aha-moment" path. A user who completes
it is one who scanned their pantry, picked a dish, cooked it quickly, and
liked the result. Drop-off between steps is the primary improvement signal
for steps 3–4 of the build order.

## Funnel steps

| # | Event                    | Match condition                          | Why this event                                          |
|---|--------------------------|------------------------------------------|---------------------------------------------------------|
| 1 | `scan_started`           | (none)                                   | Top of the funnel — the user starts capturing pantry.   |
| 2 | `suggested_dish_selected`| (none)                                   | They picked one of the 3 dinner cards.                  |
| 3 | `cook_session_completed` | (none)                                   | They reached the end of Cook Mode for that dish.        |
| 4 | `meal_rated`             | property `rating ≥ 4`                    | They rated the meal positively. Excludes skipped path.  |

## Conversion window

* **Funnel duration: 3 days max** between step 1 (scan_started) and step 4
  (meal_rated). Most converts within 60 minutes; 3 days catches "I'll cook
  this tomorrow" users without inflating with stale state.
* **Strict order** — PostHog "matching events in the specified order."
* **Distinct ID** — group by `distinct_id` (default).

## Step 3-vs-1 time gate ("within 3 min")

PostHog Funnels don't natively express "step 3 within 3 min of step 1" as a
single setting. Two ways to encode the gate:

1. **Recommended:** add an additional funnel step between (2) and (3): a
   `cook_mode_started` event with no property filter, then a **funnel
   conversion window** override on the (cook_mode_started → cook_session_completed)
   pair via the per-step gear menu — set "must convert within 3 minutes."
   This isolates the "cook within 3 min" intent to the Cook Mode segment of
   the journey (the right semantic, since the 3-min window starts when the
   user actually begins cooking, not when they tap "select").
2. Alternative: keep the funnel as-is (3-day window) and add a separate
   Trends insight `cook_session_completed` where `$time_since:
   cook_mode_started < 180 seconds`. Useful as a sanity-check chart but
   isn't itself the conversion metric.

## Property filters (none required)

The four events carry rich payloads (`scan_started.flash_mode`,
`suggested_dish_selected.dish_id`, `cook_session_completed.duration_seconds`,
`meal_rated.rating`) but the canonical funnel only filters on
`meal_rated.rating ≥ 4`. Property drill-downs (e.g. flash mode by step,
ingredient count by completion rate) are best handled as **breakdowns** on
the funnel insight, not filters.

## Suggested breakdowns

* By `scan_started.image_count` (1 vs 2–4) — single-image vs multi-image
  scan conversion delta. Pre-launch we expect single-image to dominate.
* By `suggested_dish_selected.rank` (1 / 2 / 3) — does the first card
  convert better than the third? Tells us whether the dinner-solve ranker
  is doing its job.
* By tier (`entitlement_tier` on `meal_rated`) — Free vs Premium vs Pro
  retention.

## Title / description

* **Title:** `Core success funnel (scan → cook → rate ≥4)`
* **Description:** "Primary product KPI per CLAUDE.md anchors. A user who
  completes this funnel within 3 days experienced Stir's core promise: cook
  a dinner they liked from their pantry. Drop-off between steps tells us
  whether scan, ranker, Cook Mode, or rating UX is the next thing to
  improve."

## Saved location

* **Folder:** `Product KPIs`
* **Pin to dashboard:** `Stir — product health` (alongside the SCA-316
  cluster system/health funnels).

## After saving

* Linear: paste the PostHog insight URL into SCA-331; mark Done.
* CLAUDE.md / spec: no updates needed — the wiring already exists. Only
  update if the event-naming contract changes during dashboard build (e.g.
  PostHog UI surfaces a missing property and we need to add it iOS-side).
