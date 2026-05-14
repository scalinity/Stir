# PostHog insight — `voice_conversion_event` funnel

**Definition (CLAUDE.md §Telemetry anchors):**
`voice_affordance_tapped`(free) → `paywall_viewed` → `trial_started` →
`purchase_completed`.

The highest-intent paid conversion path. A Free user explicitly reaches for
voice (the Premium-gated feature), sees the paywall, starts a trial, and
converts. CLAUDE.md billing-model section pins this as the load-bearing
revenue funnel: "voice_affordance_tapped on Free is highest-intent moment.
Lead with `stir.premium.annual.trial7`."

## Funnel steps

| # | Event                     | Match condition                                        | Why this event                                                                |
|---|---------------------------|--------------------------------------------------------|-------------------------------------------------------------------------------|
| 1 | `voice_affordance_tapped` | property `entitlement_tier = "free"`                   | Free user explicitly invoked voice — gates by tier to filter Premium+ taps.  |
| 2 | `paywall_viewed`          | property `trigger = "voice_affordance_tapped"`         | The matching paywall mount, not a paywall surfaced from a different gate.    |
| 3 | `trial_started`           | property `product_id = "stir.pro.annual"` OR similar   | The trial they enrolled in (Pro Annual is the primary trial CTA per CLAUDE.md). |
| 4 | `purchase_completed`      | property `product_id` matches step 3                    | Trial converted to paid (or any purchase). RevenueCat webhook authority.       |

## Conversion window

* **Funnel duration: 14 days** between step 1 (voice tap) and step 4
  (purchase). Trial length is 7 days; window covers trial + a few days of
  trial-end conversion lag.
* **Strict order.**
* **Distinct ID** — default `distinct_id`. For Pro/Premium tier users this
  is the canonical_user_key hash.

## Step 1 — `entitlement_tier = "free"` is mandatory

Without the tier filter, Premium+ users tapping the affordance (which leads
straight to a voice session, not a paywall) inflate the funnel's top.
CLAUDE.md telemetry block defines `voice_affordance_tapped` carries
`entitlement_tier` as a property; verify against
`PostHogClient.swift voice_affordance_tapped` capture site if the property
isn't visible in the PostHog event picker.

## Step 2 — `trigger = "voice_affordance_tapped"` is mandatory

`paywall_viewed.trigger` is an enum (CLAUDE.md telemetry list); filtering on
this value scopes the funnel to paywalls reached from the voice tap, not
from settings/quota-exhaustion/saved-favorites/etc.

## Step 3 — product_id constraint

Pro Annual `stir.pro.annual` is the PRIMARY trial CTA in the voice-triggered
paywall (CLAUDE.md billing-model). Premium Annual `stir.premium.annual.trial7`
is offered as a secondary CTA but does NOT carry a trial post-SCA-294 (the
`.trial7` suffix is historical only).

Filter step 3 on `product_id ∈ { stir.pro.annual }` to measure trial-led
conversion specifically. For non-trial purchases the funnel still works —
step 3 is `trial_started` and step 4 is `purchase_completed`; a non-trial
SKU bypasses step 3 entirely.

To capture both paths (trial-led + direct purchase):

* Make step 3 OPTIONAL via PostHog "any of these events" — `trial_started` OR
  skip-step. PostHog doesn't natively support optional funnel steps; the
  workaround is two parallel funnels:
  * **Funnel A** — trial-led path: full 4-step funnel as above.
  * **Funnel B** — direct purchase: 3 steps (skip step 3, go direct to
    `purchase_completed`).
* Sum the two funnels' step-4 conversion counts for total revenue
  attribution.

## Suggested breakdowns

* By `paywall_viewed.product_id_displayed` (Pro Annual vs Premium Annual
  vs Premium Monthly) — does the primary CTA actually convert better?
* By time-of-day on step 1 — when users invoke voice, do they convert
  later same-day or next-day?
* By scan/solve activity preceding step 1 — does a successful scan +
  cook (core_success_event) before the voice tap correlate with higher
  conversion? Pre-step-6 ramp-up signal.

## Title / description

* **Title:** `Voice → Premium conversion funnel`
* **Description:** "Free → Premium trial conversion path driven by the
  voice affordance. CLAUDE.md billing-model anchor: voice tap is the
  highest-intent paywall trigger. Drop-off between steps tells us whether
  paywall copy, trial offer, or post-trial conversion is the next thing
  to improve. Pro Annual is the primary trial CTA."

## Saved location

* **Folder:** `Product KPIs`
* **Pin to dashboard:** `Stir — product health` (and `Stir — revenue` once
  that dashboard exists).

## After saving

* Linear: paste both Funnel A and Funnel B URLs into SCA-331; mark Done.
* If `voice_affordance_tapped.entitlement_tier` isn't found in the PostHog
  event explorer (it should be — CLAUDE.md lists it), open a small
  follow-up to add the property at the capture site before closing
  SCA-331.
