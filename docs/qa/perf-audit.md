# Performance Audit — Step 9

Date: 2026-04-24
Scope: Verify spec §18 performance targets hold before TestFlight beta.
Method: Code-level anti-pattern scan (Claude, phase 3 of step 9) + Instruments measurement on physical device (Daniel, pre-beta).

Status: Code-level scan CLEAN. Device measurements pending.

---

## Targets (from brief + spec §18)

| Target | Budget | Measurement | Owner |
|---|---|---|---|
| Cold launch | < 2s on iPhone 13 | Instruments > App Launch template | Daniel, device |
| Dinner Solve TTFB (first card) | < 2s p95 | PostHog `ai_request_completed` p95 latency_ms on feature_key=`dinner_solve` | Daniel, PostHog |
| Voice Cook Mode TTFA (normal turn) | < 500ms p95 | PostHog `cook_turn_resolved.ttfa_ms` p95 WHERE `result_type=normal` (ADR 0012 split-gate) | Daniel, PostHog |
| Voice Cook Mode TTFA (tool-call turn) | < 1500ms p95 | Same, `result_type=tool_call` | Daniel, PostHog |
| Cook Mode step-to-step transition | < 200ms | `advanceStep()` timing probe (add for measurement, remove after) | Daniel, device |
| Scroll performance — Tonight Home / Dinner Options / Saved list | No drops below 120Hz on ProMotion | Instruments > Animation Hitches template | Daniel, device |

Spec §13 also sets targets on `ai_cost_usd_per_active_user` and `voice_session_tokens_p95`. Those are beta-observed metrics, not device-local.

---

## Code-level anti-pattern scan (Claude)

Scan commands run:
```bash
grep -rn "AsyncImage" Stir/ --include="*.swift"
grep -rnE "\.id\(UUID\(\)|\.id\(Date\(\)" Stir/ --include="*.swift"
grep -rn "\.onAppear" Stir/Features --include="*.swift" -A3 | grep -E "Task|await|\.fetch|\.load"
grep -rnE "var body: some View \{" Stir/Features --include="*.swift" -A2 | grep -E "\.filter\{|\.sorted\{|\.map\{"
```

All four returned zero hits. The codebase is already perf-hygienic:
- No `AsyncImage` (avoids network-on-scroll hitches)
- No unstable `.id()` patterns that would force view-tree re-diff
- No heavy `.onAppear` async bodies that would block first-frame
- No expensive `.filter/.sorted/.map` in view bodies that would re-run on every state change

Additional spot-checks:

### `List` + `ForEach` stability

Checked `Stir/Features/Saved/SavedMealsView.swift` (the biggest list surface): uses `List(filteredRows) { row in ... }` where `filteredRows: [CookingSessionRepository.SavedMealEntry]` are `Identifiable`. Stable ids = no re-diff thrash.

Checked `Stir/Features/Tonight/TonightHomeView.swift` — uses ForEach with stable enum-backed ids for section keys.

Checked `Stir/Features/Grocery/GroceryListView.swift` — uses `ForEach(items) { item in ... }` where items are `Identifiable`.

### `@Observable` view-model scope

All view models use Swift's `@Observable` macro. SwiftUI tracks only the properties a view body reads — so granular updates rather than full re-renders. This is fine performance-wise as long as view bodies don't read the entire @Observable object property-by-property in a way that triggers re-tracking.

Spot-checked `Stir/Features/CookMode/CookModeViewModel.swift`: large @Observable (1915 LOC, past the 2000 LOC trigger line per CLAUDE.md §Deferred — see "CookModeViewModel voice-telemetry extraction" deferred entry). No direct perf concern, but a split would improve re-render granularity. Tracked for v1.1 refactor; no action in step 9.

### Core Data fetch patterns

`Stir/Core/Repositories/*` use `NSFetchRequest` with predicates + sort descriptors, and invoke them from repository methods that view models call async. No `@FetchRequest` in view code (CLAUDE.md global rule: avoid `@FetchRequest` with `@Observable`). ✅

### Image caching

No `AsyncImage` uses. All user-facing imagery is either `Image.Stir.*` (bundled assets), `Image(systemName: ...)` (SF Symbols, free), or scanned photos displayed locally from `ScanViewModel`'s UIImage / bytes held in memory. No network-image scroll hazard.

---

## Device-measurement procedure (Daniel)

### Cold launch

1. Archive Release build: `xcodebuild archive -scheme Stir -destination 'generic/platform=iOS' -archivePath /tmp/Stir.xcarchive`
2. Export IPA to iPhone 13 (or closest available device).
3. Force-quit any running Stir instance. Wait 10s.
4. Xcode > Open Developer Tool > Instruments > App Launch template.
5. Target: iPhone + Stir app. Record.
6. Tap Stir icon. Wait for Tonight Home to render.
7. Stop recording. Read "Pre-main" + "main() to first frame" + "First frame to ready" segments.
8. Record total (target < 2s).

If p95 > 2s:
- Top offender is typically SPM package init (e.g., RevenueCat, Sentry). Delay non-critical init to post-launch Task.
- Next common offender: heavy `.onAppear` on root view. Lazy-load.

### Solve TTFB

1. Visit Tonight → Scan → Review → Constraints. Set a constraint like "20 minutes".
2. Tap Solve. Note wall-clock time to first dish card rendering.
3. Repeat 20 times over ~10 min spanning Wi-Fi and cellular.
4. Query PostHog:
```sql
SELECT quantile(0.95)(toFloat(properties.latency_ms)) AS p95
FROM events
WHERE event = 'ai_request_completed'
  AND properties.feature_key = 'dinner_solve'
  AND timestamp > now() - interval 1 day
```

If p95 > 2s:
- Check Supabase region vs Gemini endpoint region (§21.30 — adjacent region required).
- Check for unusually cold Gemini model starts; first solve after 15-min idle often high.
- Streaming card-by-card response may help perceived latency even if total TTFB unchanged.

### Voice Cook Mode TTFA (re-verify ADR 0012 split-gate)

Already measured in step 6; re-verify against a fresh 20-turn session.

1. Start Cook Mode voice session (Premium tier).
2. Mix of simple questions ("what's next?") and tool-call questions ("can I use oat milk?").
3. Query PostHog:
```sql
SELECT
  properties.result_type,
  quantile(0.95)(toFloat(properties.ttfa_ms)) AS p95_ttfa_ms,
  count() AS turns
FROM events
WHERE event = 'cook_turn_resolved'
  AND properties.path = 'live_api'
  AND timestamp > now() - interval 1 day
GROUP BY properties.result_type
```

Expected per ADR 0012:
- `normal` p95 < 500ms
- `tool_call` p95 < 1500ms

### Cook Mode step-to-step

Add a timing probe (remove before submission):

```swift
// CookModeViewModel.swift — advanceStep()
func advanceStep() {
    let t0 = CFAbsoluteTimeGetCurrent()
    defer {
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if elapsed > 200 {
            Logger.perf.warning("step advance took \\(elapsed, privacy: .public)ms")
        }
    }
    // ...existing body...
}
```

Walk a full Cook Session. Check Console.app for any warnings. Target: 0 warnings.

### Scroll performance

1. Instruments > Animation Hitches template.
2. Target: iPhone + Stir.
3. Scroll aggressively on: Tonight Home (30s), Dinner Options (30s), Saved list with ≥20 entries (30s).
4. Look for hitch events. Target: 0 hitches below 120Hz on ProMotion device.

If hitches observed:
- Check `body` closure for non-idempotent reads (state mutation during render = re-render loop).
- Check for large images without prerender (there shouldn't be any; see "Image caching" section above).
- Check List vs LazyVStack for memory pressure at large row counts.

---

## Sign-off

Code-level perf anti-pattern scan: COMPLETE, zero hits.
Device-level Instruments measurements: pending Daniel on TestFlight build.
Beta-observed telemetry targets (AI cost, voice tokens): pending 2-week beta period (Phase 7).

Regression tracking: any target missed on beta build should be logged here with measurement, triage, and fix (or accepted-debt rationale with v1.1 revisit trigger).
