# PostHog product-funnel insights (SCA-331)

CLAUDE.md telemetry §"Anchors" defines two canonical product KPIs whose
client-side emission is wired but whose PostHog dashboards still need to be
built:

* **`core_success_event`** = scan → select → cook within 3 min → rate ≥4
* **`voice_conversion_event`** = `voice_affordance_tapped`(free) →
  `paywall_viewed` → `trial_started` → `purchase_completed`

This directory holds the funnel definitions in a vendor-neutral spec form so
they can be (re)created in the PostHog UI without rummaging through
`PostHogClient.swift` to remember which property carries which value.

Files:

* [`core_success_event.md`](./core_success_event.md) — primary product funnel
* [`voice_conversion_event.md`](./voice_conversion_event.md) — Free → Premium
  trial conversion funnel

## How to apply

PostHog Cloud → Stir org → **Insights → New insight → Funnel** → add each
step as listed in the spec doc. Use the property filters and the `match by`
columns exactly as written; the property contracts come straight from
CLAUDE.md §"Telemetry events" and `Stir/Integrations/PostHog/PostHogClient.swift`.

When the funnels exist, link them from the Step 8 product-health dashboard
referenced in `CLAUDE.md` (system/health metrics shipped via SCA-316 cluster;
product-funnel side was deferred to SCA-331).

## Why not commit JSON

PostHog's insight-export format includes account/team IDs and timestamps that
make it more drift-prone than a vendor-neutral spec. The markdown form below
is the canonical source; the JSON inside PostHog is the manifestation.
