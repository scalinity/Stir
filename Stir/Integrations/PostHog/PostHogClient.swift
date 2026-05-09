// PostHogClient
//
// Thin singleton wrapper around `PostHogSDK.shared`. Matches the step-2
// prompt's telemetry contract:
//   - Initialize at launch
//   - identify(distinctID:) after canonical key resolves (distinctID = hash)
//   - capture("app_opened", …) on cold start
//   - capture("onboarding_started" / "onboarding_completed" / "app_backgrounded")
//
// CLAUDE.md §"Telemetry events" is the canonical allow-list. Inventing new
// event names in code without updating spec §15 + CLAUDE.md is banned.

import Foundation
import OSLog
import PostHog

/// Non-final + `open capture(...)` so tests can subclass with a spy.
/// The singleton is the only caller outside tests, so the virtual
/// dispatch cost is irrelevant in production.
class PostHogClient: @unchecked Sendable {
    static let shared = PostHogClient()
    private let lock = NSLock()
    private var _isInitialized = false

    private var isInitialized: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isInitialized
    }

    private init() {}

    /// Initialize the PostHog SDK. Idempotent under concurrent callers — the
    /// lock + double-check prevents two racing initializers from both
    /// getting past the guard and double-configuring the SDK.
    func initialize(apiKey: String, host: URL) {
        lock.lock()
        if _isInitialized { lock.unlock(); return }
        _isInitialized = true
        lock.unlock()

        let config = PostHogConfig(apiKey: apiKey, host: host.absoluteString)
        // Auto-lifecycle disabled (2026-04-24): the SDK fires `Application
        // Opened / Backgrounded / Installed` the moment `setup(...)`
        // completes, attributed to an anonymous distinct_id because
        // `identify(keyHash)` doesn't happen until after CloudKit +
        // install-ID resolution in RootCoordinator. That bifurcated the
        // identity graph AND introduced four events that violate
        // CLAUDE.md's canonical allow-list (`TelemetryEvent` enum).
        // Stir emits its own `app_opened` / `app_backgrounded` with
        // the properly hashed canonical_user_key; those are the single
        // source of truth.
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false  // step-2 doesn't want auto screen events
        config.sessionReplay = false        // replays off until we've vetted privacy
        config.flushAt = 10
        config.flushIntervalSeconds = 30
        PostHogSDK.shared.setup(config)
        Logger.telemetry.info("posthog initialized (host=\(host.host ?? "?", privacy: .public))")
    }

    /// Bind the session to a distinct ID (the canonical_user_key_hash).
    func identify(distinctID: String) {
        guard isInitialized else { return }
        PostHogSDK.shared.identify(distinctID)
    }

    /// Alias the CURRENT distinct ID to `newDistinctID` — merges the two
    /// identities into one PostHog person. Called on install:→ck:
    /// migration so the `voice_conversion_event` funnel (spec §15 line
    /// 1641) doesn't fragment at every paid conversion. Must be called
    /// BEFORE `identify(newDistinctID)` so the SDK ties the alias to
    /// the previous-key person, not the new one.
    ///
    /// ADR 0009 + SA2-C1 (2026-04-24): prior to this method, identity
    /// transitions were handled by `identify()` alone, which PostHog
    /// treats as "the current device is now a different person" — no
    /// merge. Paid Premium conversions attributed to two distinct
    /// persons, breaking Premium-tier metric reconciliation.
    func alias(to newDistinctID: String) {
        guard isInitialized else { return }
        PostHogSDK.shared.alias(newDistinctID)
    }

    /// Reset the SDK's local state — rotates `$device_id`, clears the
    /// event queue, and unbinds `distinct_id`. Called on genuine A→B
    /// user flip (two different CloudKit accounts sharing a device)
    /// where aliasing would incorrectly merge them. Must be paired with
    /// a fresh `identify(...)` immediately after.
    func reset() {
        guard isInitialized else { return }
        PostHogSDK.shared.reset()
    }

    /// Emit a typed event. Properties are Sendable JSON-compatible values.
    func capture(_ event: TelemetryEvent, properties: [String: Any] = [:]) {
        guard isInitialized else { return }
        PostHogSDK.shared.capture(event.rawValue, properties: properties)
    }

    /// Emit a `$ai_trace` event for PostHog LLM Observability.
    ///
    /// Trace lifecycle (ADR 0009 + spec §15 dashboard-join contract):
    /// iOS fires EXACTLY ONE `$ai_trace` per voice session, at session
    /// close, carrying BOTH `$ai_input_state` (captured at VM attach
    /// time) AND `$ai_output_state` (session totals) in the same
    /// emission. The backend does NOT emit a sibling mint-time trace
    /// — PostHog is append-only, so a mint+close pair would create two
    /// sibling rows rather than a single merged record (the documented
    /// rejection in ADR 0009). See
    /// `CookModeViewModel.fireVoiceSessionCloseTrace` for the single
    /// call site and `_shared/ai_observability.ts` lines 170-174 for
    /// the backend's explicit "no mint-time trace" contract.
    ///
    /// Privacy: no user content. `inputState` / `outputState` must
    /// contain only metadata (turn counts, token totals, ended_reason,
    /// duration_ms). Recipe titles, transcripts, or AI responses MUST
    /// NOT be placed in either state map.
    func captureAITrace(
        traceID: String,
        spanName: String,
        inputState: [String: Any]? = nil,
        outputState: [String: Any]? = nil,
        feature: String? = nil,
    ) {
        guard isInitialized else { return }
        var properties: [String: Any] = [
            "$ai_trace_id": traceID,
            "$ai_span_name": spanName,
        ]
        if let inputState { properties["$ai_input_state"] = inputState }
        if let outputState { properties["$ai_output_state"] = outputState }
        if let feature { properties["feature"] = feature }
        PostHogSDK.shared.capture("$ai_trace", properties: properties)
    }

    #if DEBUG
    /// Protected init so tests can subclass with an override of
    /// `capture(...)`. DEBUG-only so production builds can't
    /// accidentally construct an uninitialized instance and bypass
    /// the singleton.
    init(testingOnly: Bool) {}
    #endif
}

/// Canonical event name allow-list. Adding one requires updating both
/// CLAUDE.md §"Telemetry events" and spec §15.
enum TelemetryEvent: String, Sendable, CaseIterable {
    case appOpened = "app_opened"
    case appBackgrounded = "app_backgrounded"
    case onboardingStarted = "onboarding_started"
    case onboardingCompleted = "onboarding_completed"
    case screenErrorShown = "screen_error_shown"
    case syncStateChanged = "sync_state_changed"
    case entitlementStateChanged = "entitlement_state_changed"
    // Step 3 — scan + solve
    case cameraPermissionResult = "camera_permission_result"
    case scanStarted = "scan_started"
    case scanSubmitted = "scan_submitted"
    case scanParseCompleted = "scan_parse_completed"
    case ingredientCorrected = "ingredient_corrected"
    case constraintsSet = "constraints_set"
    case dinnerSolveRequested = "dinner_solve_requested"
    case dinnerSolveCompleted = "dinner_solve_completed"
    case suggestedDishSelected = "suggested_dish_selected"
    case aiRequestCompleted = "ai_request_completed"
    case aiRequestFailed = "ai_request_failed"
    // Step 4 — tap Cook Mode + substitution + outcome feedback.
    case cookModeStarted = "cook_mode_started"
    case cookStepAdvanced = "cook_step_advanced"
    case timerStarted = "timer_started"
    case substitutionRequested = "substitution_requested"
    case substitutionAccepted = "substitution_accepted"
    case cookSessionCompleted = "cook_session_completed"
    /// Fires once per `cook_session_completed`, immediately after
    /// `PantryItemRepository.consumeForRecipe` runs (ADR 0029 /
    /// SCA-21). The auto-consume rule is memory-state-aware:
    /// matched-and-`.ephemeral` rows soft-delete, matched-and-
    /// `.remembered` rows bump `lastSeenAt`, others no-op. Properties
    /// are counts only — never ingredient names — to satisfy ADR 0009's
    /// privacy invariant. Emitted unconditionally (even on an all-
    /// zeros outcome) so the event time-series stays continuous and
    /// missing emissions flag a wiring regression.
    case pantryAutoConsumeResolved = "pantry_auto_consume_resolved"
    /// SCA-97: emitted by `PantryTombstoneReaper.runIfDue(...)` after
    /// every successful purge pass — including zero-row passes — so
    /// the funnel sees continuous cadence coverage. Properties:
    ///   - `rows_purged`: integer ≥ 0 — rows hard-deleted this run
    ///   - `retention_days`: integer — retention window in whole days
    ///     (default 90; configurable for tests / future tier scaling)
    ///
    /// Failed runs (Core Data fault during fetch/save) emit nothing
    /// and retry on the next foreground; the cadence timestamp moves
    /// only after success, so failures don't poison the schedule.
    /// Counts only; no item names per ADR 0009's privacy invariant.
    case pantryTombstoneReaperRan = "pantry_tombstone_reaper_ran"
    /// SCA-99 / ADR 0035: emitted by `EntitlementService.applyTierChange`
    /// after `PantryItemRepository.reconcileForTierChange` completes a
    /// soft-archive pass on a tier-downgrade hydrate (Premium/Pro → Free
    /// or Pro → Premium). Fires unconditionally on every detected
    /// downgrade — including zero-archive passes (when `used <= cap`
    /// already) — so the dashboard signal is "downgrade event reached
    /// reconciliation" not "downgrade event archived something".
    /// Missing emissions on a confirmed billing-state delta indicate
    /// the `applyTierChange` hook is detached from `hydrate`.
    ///
    /// Properties:
    ///   - `previous_tier`: free|premium|pro — the tier the snapshot
    ///     was at before the new hydrate landed.
    ///   - `new_tier`: free|premium|pro — the tier on the incoming
    ///     entitlement.
    ///   - `archived_count`: integer ≥ 0 — `.remembered` rows the
    ///     reconciler soft-archived to `.ephemeral` this pass.
    ///   - `total_remembered_pre`: integer ≥ 0 — count of
    ///     `.remembered` rows before reconciliation (excludes
    ///     soft-deleted).
    ///   - `total_remembered_post`: integer ≥ 0 — count after.
    ///     Equals `min(total_remembered_pre, new_cap)` when
    ///     `archived_count > 0`.
    ///
    /// No item names or pantry content per ADR 0009's privacy
    /// invariant.
    case pantryTierDowngradeReconciled = "pantry_tier_downgrade_reconciled"
    case mealRated = "meal_rated"
    /// Fires when the user dismisses the outcome feedback sheet via Skip
    /// without submitting a rating. Complement to `meal_rated` — the pair
    /// measures whether users actually rate vs opt out, which the
    /// north-star `core_success_event` funnel is blind to when only
    /// ratings are measured. Sheet opens on every `cook_session_completed`;
    /// TYPICALLY one of {meal_rated, meal_rating_skipped} follows — force-
    /// quit / crash / background-kill between sheet open and dismissal
    /// yield zero emissions, a valid third state.
    case mealRatingSkipped = "meal_rating_skipped"
    // Step 5 — billing + paywall.
    case paywallViewed = "paywall_viewed"
    case trialStarted = "trial_started"
    case purchaseStarted = "purchase_started"
    case purchaseCompleted = "purchase_completed"
    case restorePurchasesTapped = "restore_purchases_tapped"
    case favoriteSaved = "favorite_saved"
    // Defined now so step 6 wiring doesn't re-register the enum case.
    // No invocation path in step 5.
    case voiceAffordanceTapped = "voice_affordance_tapped"
    // Step 6 C.4 — voice cook-turn events. Spec §15 verbatim.
    case cookTurnSubmitted = "cook_turn_submitted"
    case cookTurnResolved = "cook_turn_resolved"
    // Step 6 C.5 — session-observability events. Both emitted by the
    // VM on turn-boundary callbacks from RealtimeSession. Spec §15
    // verbatim; property contracts enforced at emission sites.
    case voiceSessionTokenSnapshot = "voice_session_token_snapshot"
    case voiceSessionRefreshed = "voice_session_refreshed"
    // Step 6 (late) — stuck-modelSpeaking watchdog fire. Gemini Live
    // occasionally drops `turnComplete` on multi-pass tool-call turns
    // (observed 2026-04-23); the watchdog synthesizes the transition.
    // Emission carries {session_id, turn_index, tool_call_type,
    // elapsed_stuck_ms, turn_length_at_stuck}. Not part of spec §15 —
    // added as an ops-only signal; monitor threshold per ADR 0015
    // (>5% of tool-call turns = revisit vendor contingency).
    case voiceTurnStuckWatchdogFired = "voice_turn_stuck_watchdog_fired"
    // Reserved for step 8 (reactivation campaigns). CLAUDE.md canonical.
    case reactivationNotificationOpened = "reactivation_notification_opened"
    // SCA-65 — leftovers followup scheduler lifecycle. Spec §15 +
    // CLAUDE.md canonical. _scheduled fires once per successful schedule
    // (post-cap, post-suppression checks); _fired emits at delivery via
    // StirNotificationDelegate; _tapped on deep-link tap; _suppressed
    // emits at scheduling time when a cap or unactioned-streak guard
    // blocks the schedule (carries `reason`).
    case leftoversFollowupScheduled  = "leftovers_followup_scheduled"
    case leftoversFollowupFired      = "leftovers_followup_fired"
    case leftoversFollowupTapped     = "leftovers_followup_tapped"
    case leftoversFollowupSuppressed = "leftovers_followup_suppressed"
    // SCA-64 — use-soon notification lifecycle. Same shape as
    // leftovers_followup_*; spec §15 + CLAUDE.md canonical. _suppressed
    // carries `reason ∈ {weekly_cap, unactioned_streak, recent_session,
    // no_candidate}`. _scheduled carries {fire_at, item_display_name}.
    case useSoonScheduled  = "use_soon_scheduled"
    case useSoonFired      = "use_soon_fired"
    case useSoonTapped     = "use_soon_tapped"
    case useSoonSuppressed = "use_soon_suppressed"
    // SCA-66 — high-rated repeat candidate card lifecycle. Spec §15 +
    // CLAUDE.md canonical. _shown carries {recipe_plan_id, tier};
    // _dismissed carries {recipe_plan_id, outcome ∈ {paywall_routed,
    // deferred, suppressed}}. The "saved" outcome reuses the existing
    // `favorite_saved` event with `source = "post_meal_feedback"`
    // (no new event for the success path — keeps the favorite funnel
    // single-event).
    case repeatCandidateCardShown     = "repeat_candidate_card_shown"
    case repeatCandidateCardDismissed = "repeat_candidate_card_dismissed"
    // SCA-67 — Welcome "See a sample" showcase. Spec §15 + CLAUDE.md
    // canonical. _viewed fires on showcase appear; _exited carries
    // {outcome ∈ {continued_to_onboarding, back_to_welcome}}.
    case sampleShowcaseViewed = "sample_showcase_viewed"
    case sampleShowcaseExited = "sample_showcase_exited"
    // SCA-72 — widget nudge in-app card lifecycle. Spec §15 + CLAUDE.md
    // canonical. _shown emits when the nudge is composed onto Tonight
    // Home. _dismissed carries `outcome ∈ {acted, deferred, suppressed}`.
    case widgetNudgeShown     = "widget_nudge_shown"
    case widgetNudgeDismissed = "widget_nudge_dismissed"
    // Step 7 — import + grocery + widgets/shortcuts. Property names below
    // are spec §15 canonical (destination NOT export_target; parse_quality
    // NOT confidence; edit_required NOT needed_edits). No `widget_tapped`
    // — a widget deep-link tap fires `app_opened` with the URL param.
    case recipeImportStarted = "recipe_import_started"
    case recipeImportCompleted = "recipe_import_completed"
    case widgetAdded = "widget_added"
    case shortcutRun = "shortcut_run"
    case groceryListExported = "grocery_list_exported"
    /// SCA-55 — Leftovers handoff. Fires when a Premium+ user picks a
    /// dish from `LeftoversRoot` and it's persisted as a new RecipePlan
    /// via `SolveRepository.createLeftoversSolveWithDish`. Properties:
    /// `rank` (1..3), `leftovers_items_count`, `prompt_version`,
    /// `source_recipe_plan_id` (the meal that produced the leftovers),
    /// `new_recipe_plan_id` (the persisted leftover plan), `persist_ms`
    /// (SCA-106 — background-context save latency for the leftovers
    /// solve persist; powers the long-tail dashboard signal that
    /// motivated the bg-context migration). Pairs with the
    /// `meal_rated.leftovers_handoff_*` properties for the full
    /// Premium-side conversion funnel; Free-side conversion lives on
    /// `paywall_viewed.trigger=leftovers_gate` → `purchase_completed`.
    case leftoversDishSelected = "leftovers_dish_selected"
    /// SCA-148 — fires when CookModeViewModel.matchIngredient detects a
    /// same-length tie among substring candidates for a voice
    /// substitution. Properties: `session_id`, `candidate_count`
    /// (≥2), `surface` ∈ {voice, tap}, `resolved_to` ∈ closed enum
    /// in `VoiceSessionTelemetry.SubstitutionDisambiguationResolution`.
    /// Today's only emit path is the voice surface routing ambiguous
    /// matches to free-text persistence (`resolved_to=free_text_fallback`);
    /// other resolution values are reserved for the future
    /// mid-turn-prompt UX. Dashboard: rate of fire vs total voice subs
    /// — ≥1% justifies the prompt-UX build-out per SCA-148 ticket.
    case voiceSubstitutionDisambiguated = "voice_substitution_disambiguated"
    // SCA-5 — in-app feature tutorials. Fired once per tutorial-key
    // lifecycle: started on first appear, then exactly one of
    // {completed, skipped} on resolution. `tutorial_step_advanced`
    // fires on every advance for funnel-drop-off analysis. Properties
    // are minimal: `tutorial_id` (TutorialKey.telemetryID) plus
    // `from_step`/`to_step` for the step event. Not yet in spec §15 —
    // tracked as a follow-up; see CLAUDE.md telemetry list.
    case tutorialStarted = "tutorial_started"
    case tutorialCompleted = "tutorial_completed"
    case tutorialSkipped = "tutorial_skipped"
    case tutorialStepAdvanced = "tutorial_step_advanced"
}

/// Typed property-bag helpers for step-7 events. Keeping properties
/// off a loose [String: Any] dict at call sites prevents the
/// `export_target` / `confidence` / `needed_edits` drift that the
/// telemetry snapshot test watches for.
public enum StepSevenTelemetry {
    /// `recipe_import_started` — one event per user-initiated import.
    /// Properties: source_type (spec §15).
    public static func recipeImportStarted(source: RecipeImportSource) -> [String: Any] {
        ["source_type": source.rawValue]
    }

    /// `recipe_import_completed` — fires on final Import Review
    /// acceptance OR on user cancellation OR on AI failure.
    /// Properties: source_type, parse_quality, edit_required (spec §15).
    public static func recipeImportCompleted(
        source: RecipeImportSource,
        parseQuality: String,
        editRequired: Bool,
    ) -> [String: Any] {
        [
            "source_type": source.rawValue,
            "parse_quality": parseQuality,
            "edit_required": editRequired,
        ]
    }

    /// `widget_added` — fired when `WidgetCenter.shared.reloadAllTimelines()`
    /// observes a new widget configuration. Properties: source (spec §15).
    public static func widgetAdded(source: String) -> [String: Any] {
        ["source": source]
    }

    /// `shortcut_run` — AppIntent invocation. Fires on BOTH successful
    /// runs and entitlement-gated no-ops (gate shows up as `intent_name`
    /// + separate entitlement_state_changed). Properties: intent_name.
    public static func shortcutRun(intentName: String) -> [String: Any] {
        ["intent_name": intentName]
    }

    /// `grocery_list_exported` — post-EventKit export success. Also fired
    /// with `destination: "in_app"` when Reminders was denied and the
    /// list stayed in Stir. Properties: item_count, destination.
    public enum GroceryExportDestination: String, Sendable {
        case reminders
        case inApp = "in_app"
    }

    public static func groceryListExported(
        itemCount: Int,
        destination: GroceryExportDestination,
    ) -> [String: Any] {
        [
            "item_count": itemCount,
            "destination": destination.rawValue,
        ]
    }

    /// `dinner_solve_requested` — one event per user-initiated solve.
    /// `contextHint` discriminates the leftovers path ("leftovers") from
    /// the primary pantry-scan path (nil → omitted from properties).
    /// `leftoversItemsCount` is 0 for primary solves, >0 for leftovers.
    /// Keeping the helper typed prevents the "typo in context_hint"
    /// funnel-corruption hazard CR2-26 flagged.
    public static func dinnerSolveRequested(
        contextHint: String? = nil,
        leftoversItemsCount: Int = 0,
    ) -> [String: Any] {
        var props: [String: Any] = [:]
        if let contextHint { props["context_hint"] = contextHint }
        if leftoversItemsCount > 0 { props["leftovers_items_count"] = leftoversItemsCount }
        return props
    }

    /// `dinner_solve_completed` — terminal event on the SSE stream's
    /// `done` frame. Carries cost + retry + prompt version for the
    /// ops dashboard.
    public static func dinnerSolveCompleted(
        contextHint: String? = nil,
        dishesReturned: Int,
        totalCostUSD: Double,
        retryCount: Int,
        promptVersion: String,
        totalLatencyMs: Int,
    ) -> [String: Any] {
        var props: [String: Any] = [
            "dishes_returned": dishesReturned,
            "total_cost_usd": totalCostUSD,
            "retry_count": retryCount,
            "prompt_version": promptVersion,
            "total_latency_ms": totalLatencyMs,
        ]
        if let contextHint { props["context_hint"] = contextHint }
        return props
    }

    /// Destination values match spec §15 verbatim. DO NOT add new values
    /// without updating spec + CLAUDE.md + the snapshot test.
    public enum Destination: String, Sendable, CaseIterable {
        case reminders
        case inApp = "in_app"
    }

    /// `reactivation_notification_opened` — local-notification deep link.
    /// Properties: trigger_kind. Values restricted to spec §8 triggers.
    public static func reactivationNotificationOpened(triggerKind: String) -> [String: Any] {
        ["trigger_kind": triggerKind]
    }
}
