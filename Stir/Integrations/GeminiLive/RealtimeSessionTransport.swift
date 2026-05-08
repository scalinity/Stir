// RealtimeSessionTransport
//
// SCA-79 — extracted from RealtimeSession.swift. Owns two related but
// distinct concerns (after SCA-161 moved handleTransportError out into
// the StateMachine bucket):
//
//   - **WS transport plumbing**: token-mint request building,
//     household-context projection (with TTL cache),
//     `startReceiveDispatcher` (the inbound frame Task),
//     `awaitSetupComplete` continuation pattern.
//   - **Tool-call round-trip**: `handleToolCall` + `dispatchTool` +
//     `dispatchSubstitution` + the timer-snapshot helpers
//     (`snapshotToDict`, `makeNoneTimerSnapshot`, `makeStepResponse`).
//     Tool-call dispatch is application-layer behavior — it touches
//     `turnContainedToolCall` / `lastToolCallName`, the substitution
//     callbacks, the timer callbacks, and the recipe domain. The trigger
//     just happens to arrive over the wire.
//
// SCA-79 review W4 (CR1): tool-call dispatch is ~70% of this file.
// Eventual extraction into a dedicated `RealtimeSessionTools.swift` is
// tracked in `docs/deferred-work.md` (trigger: this file > ~1,800 LOC,
// OR Gemini Live moves to GA, OR a third bucket needs cross-coupling).
// Until then, the `// MARK: - tool-call round-trip` section header at
// the boundary lets Xcode's symbol jumper navigate cleanly.
//
// All instance stored properties (transport, dispatcherGeneration,
// receiveDispatcherTask, cachedHouseholdContext + ...At,
// setupCompleteContinuation, setupCompleteGeneration, etc.) live on
// the main RealtimeSession class declaration in RealtimeSession.swift.
// Methods here read them via `self`.
//
// Logger.voice is declared in `Speech/AVAudioSessionConfigurator.swift`
// (cross-bucket dependency); a future Speech-bucket relocation must
// keep the `static let voice` declaration reachable from this file.

import Foundation
import OSLog

extension RealtimeSession {

    // MARK: - mint + setup

    /// Shared coercion mirror of `CookModeViewModel.safeInstructionText`.
    /// Keeps buildMintRequest's allSteps + currentStepText Zod-safe
    /// without depending on the VM class.
    ///
    /// SCA-168 S15 (DB1): file-scoped `private static`. Must stay
    /// co-located with `buildMintRequest` (sole caller). A future
    /// refactor that moves `buildMintRequest` out of this file must
    /// move this helper alongside, OR the move will orphan the call
    /// sites and break compilation.
    private static func safeInstructionText(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "(step instruction unavailable)" : trimmed
    }

    /// SCA-168 S16 (SA2): security invariant — this routine MUST read
    /// `cookingSession.id` / `recipePlan.id` from the bound `cookingSession`
    /// and never accept caller-supplied substitutes. The
    /// `init(testingOnlyMintResponse:...)` DEBUG-only initializer in
    /// the main file pre-populates `mintResponse` directly without
    /// hitting this code path, so the invariant is intact in release
    /// builds. A future caller that wants to mint against a different
    /// cooking session must construct a separate `RealtimeSession`
    /// instance — do not parameterize this method.
    func buildMintRequest(
        recap: String? = nil,
        isRefresh: Bool = false,
    ) throws -> RealtimeSessionRequest {
        guard let sessionID = cookingSession.id else {
            throw RealtimeSessionError.mintFailed(message: "cooking session has no id")
        }
        guard let recipePlan = cookingSession.recipePlan,
              let recipePlanID = recipePlan.id
        else {
            throw RealtimeSessionError.mintFailed(message: "cooking session has no recipe_plan")
        }
        let steps = recipePlan.stepArray
        let currentIndex = Int(cookingSession.currentStepIndex)
        let currentStep = steps.indices.contains(currentIndex) ? steps[currentIndex] : nil
        let currentStepNumber = currentIndex + 1

        // Empty/whitespace-only instruction text would VAL-01 the mint
        // (Zod `text: z.string().min(1)` and `current_step_text:
        // z.string().min(1)`). Coerce to a placeholder so malformed
        // imports don't silently downgrade users to C.3. Mirrors the
        // VM-side `CookModeViewModel.safeInstructionText`.
        let allSteps = steps.map {
            RealtimeRecipeContext.StepDescription(
                stepNumber: Int($0.stepNumber),
                text: Self.safeInstructionText($0.instructionText),
                // 0 = no timer. Backend schema requires the key present.
                timerSeconds: Int($0.timerSeconds),
            )
        }
        let recipeContext = RealtimeRecipeContext(
            title: recipePlan.title ?? "",
            servings: Int(recipePlan.servings),
            estimatedMinutes: Int(recipePlan.estimatedMinutes),
            totalSteps: steps.count,
            currentStepText: Self.safeInstructionText(currentStep?.instructionText),
            // 0 when no timer on this step (or no current step). DTO
            // is non-Optional because the backend requires the key to
            // be present even when null — explicit 0 is the simplest
            // encoding that always satisfies the schema.
            currentStepTimerSeconds: Int(currentStep?.timerSeconds ?? 0),
            allSteps: allSteps,
            remainingIngredients: recipePlan.ingredientArray.map { ing in
                .init(displayName: ing.displayName ?? "", canonicalSlug: ing.canonicalIngredientSlug)
            },
        )
        let householdContext = buildHouseholdContext()

        return RealtimeSessionRequest(
            clientRequestID: UUID(),
            cookingSessionID: sessionID,
            recipePlanID: recipePlanID,
            currentStepNumber: max(1, currentStepNumber),
            recipeContext: recipeContext,
            householdContext: householdContext,
            recap: recap,
            isRefresh: isRefresh,
        )
    }

    private func buildHouseholdContext() -> RealtimeHouseholdContext {
        // P2-I (2026-04-23): routed through
        // `HouseholdProfile.voiceContextSnapshot()` shared seam so the
        // mint + VM + substitution paths all project with identical
        // filters. Prior three call-site drift fixed there.
        //
        // P3-H (2026-04-23): TTL-cache the snapshot so refresh mints
        // don't re-walk the full pantry set (up to 1000 items for Pro)
        // on every refresh. 60 s TTL balances cost-of-recompute
        // against cost-of-stale (a user deleting a pantry item via
        // another app mid-session waits up to 60 s before the new
        // session-refresh picks it up — acceptable since the stale
        // view still matches what iOS's own Cook Mode UI shows).
        let now = Date()
        if let cached = cachedHouseholdContext,
           let cachedAt = cachedHouseholdContextAt,
           now.timeIntervalSince(cachedAt) < Self.householdContextTTLSec {
            return cached
        }
        let ctx: RealtimeHouseholdContext
        if let household = cookingSession.household {
            ctx = RealtimeHouseholdContext(snapshot: household.voiceContextSnapshot())
        } else {
            ctx = RealtimeHouseholdContext(snapshot: .empty)
        }
        cachedHouseholdContext = ctx
        cachedHouseholdContextAt = now
        return ctx
    }

    private static let householdContextTTLSec: TimeInterval = 60  // SCA-168 S15: file-scoped private; must stay co-located with buildHouseholdContext.

    func clearHouseholdContextCache() {
        cachedHouseholdContext = nil
        cachedHouseholdContextAt = nil
    }

    // MARK: - inbound dispatch

    func startReceiveDispatcher() {
        guard let transport else { return }
        dispatcherGeneration += 1
        let myGen = dispatcherGeneration
        // SCA-170 S14 (CA3): annotate the unstructured Task with `@MainActor`
        // so the catch-block read of `dispatcherGeneration` (MainActor-isolated)
        // doesn't require an actor hop. Cold-path only — fires once per
        // dispatcher tear-down — but the explicit annotation also uniformizes
        // the threading model with the other awaitX timeout Tasks in this file.
        receiveDispatcherTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await frame in transport.inbound {
                    // SCA-170 S11 (CA2): defense-in-depth against
                    // close-during-frame-delivery races. The state-machine
                    // `handleInboundFrame.closed` short-circuit at the top of
                    // that method already covers this for already-delivered
                    // frames; this guard cuts the loop earlier so any frame
                    // still queued in `transport.inbound` after a cancel
                    // doesn't trigger a needless dispatch.
                    if Task.isCancelled { return }
                    await self.handleInboundFrame(frame)
                }
            } catch {
                // Generation check: if another dispatcher has since been
                // started (via refreshSession or close+restart), this
                // task is stale and its error is noise from an intentional
                // teardown. Log at info and return. Race-free because both
                // reads happen on the @MainActor (SCA-170 S14: now
                // explicit on the Task closure too).
                let current = self.dispatcherGeneration
                if myGen != current {
                    Logger.voice.info(
                        "live_receive_dispatcher_stale_suppressed gen=\(myGen, privacy: .public) current=\(current, privacy: .public)",
                    )
                    #if DEBUG
                    VoiceSessionLog.log("receive.stale_suppressed", [
                        "gen": myGen,
                        "current": current,
                    ])
                    #endif
                    return
                }
                Logger.voice.warning(
                    "live_receive_dispatcher_failed error=\(error.localizedDescription, privacy: .private)",
                )
                await self.handleTransportError(error)
            }
        }
    }

    /// Await the server's `setupComplete` handshake frame. Returns when
    /// `handleInboundFrame` resumes the continuation; throws
    /// `RealtimeSessionError.setupTimeout` if the budget elapses first.
    ///
    /// Implementation note: earlier drafts used a TaskGroup with one
    /// task blocking on the continuation and another on a timer.
    /// `TaskGroup.cancelAll()` does NOT propagate into a
    /// `withCheckedThrowingContinuation` — the continuation never
    /// resumed and leaked. This version resolves the continuation
    /// explicitly from the timeout path, so neither side leaks.
    func awaitSetupComplete(timeoutSec: Double) async throws {
        setupCompleteGeneration += 1
        let gen = setupCompleteGeneration
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.setupCompleteContinuation = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSec))
                guard let self,
                      self.setupCompleteGeneration == gen,
                      let pending = self.setupCompleteContinuation
                else { return }
                self.setupCompleteContinuation = nil
                pending.resume(throwing: RealtimeSessionError.setupTimeout)
            }
        }
    }

    // MARK: - tool-call round-trip

    func handleToolCall(_ toolCall: LiveToolCall) async {
        // Hands-free: tool calls can arrive from any live turn state —
        // VAD drives transitions server-side and the server can decide
        // to invoke `advance_step` / `start_timer` / `substitution_check`
        // at any point in the turn cycle. Reject only from terminal
        // / pre-session states where we genuinely can't respond.
        //
        // Observed 2026-04-22: model called `advance_step` while state
        // was `.userSpeaking` (VAD had heard "move on to step three"
        // but iOS hadn't advanced state yet). Old `.thinking`-only
        // guard dropped the call, server sent toolCallCancellation,
        // screen never advanced. Fix: allow .userSpeaking, .ready,
        // .modelSpeaking, .thinking, .toolCalling (re-entrant) as
        // valid source states.
        let liveStates: Set<VoiceSessionState> = [
            .userSpeaking, .ready, .modelSpeaking, .thinking, .toolCalling,
        ]
        guard liveStates.contains(stateMachine.state) else {
            Logger.voice.warning(
                "live_tool_call_in_unexpected_state state=\(self.stateMachine.state.rawValue, privacy: .public)",
            )
            #if DEBUG
            VoiceSessionLog.log("tool_call.dropped_bad_state", [
                "state": stateMachine.state.rawValue,
                "calls": toolCall.functionCalls.map(\.name).joined(separator: ","),
            ])
            #endif
            if let cont = turnCompleteContinuation {
                turnCompleteContinuation = nil
                cont.resume(throwing: RealtimeSessionError.turnDrained)
            }
            return
        }
        // Self-transitions are idempotent no-ops at the machine layer
        // (see VoiceSessionStateMachine.advance), so this call is safe
        // whether we're already in `.toolCalling` (re-entrant tool
        // frame) or transitioning from `.userSpeaking` / `.ready` /
        // `.modelSpeaking` / `.thinking`.
        stateMachine.advance(to: .toolCalling)
        // Mark the current turn as tool-involving so finalizeTurn() can
        // latch it into PendingTurnReport.containedToolCall and the VM
        // tags cook_turn_resolved.result_type accordingly (ADR 0012).
        turnContainedToolCall = true
        // Capture the most-recent tool name for the stuck-watchdog
        // PostHog payload. 3.1 Flash Live is synchronous one-in-flight
        // (CLAUDE.md §sharp-edge #12), so this is the only tool call
        // for this turn in practice. Pre-dispatch so the name is
        // available even if dispatchTool throws.
        lastToolCallName = toolCall.functionCalls.first?.name
        #if DEBUG
        VoiceSessionLog.log("tool_call.received", [
            "calls": toolCall.functionCalls.map(\.name).joined(separator: ","),
        ])
        #endif

        // 3.1 Flash Live does synchronous tool calls — one in flight
        // at a time (CLAUDE.md §sharp-edge #12). So iterating the
        // (length-1) array in order is the right contract.
        for call in toolCall.functionCalls {
            let response = await dispatchTool(call)
            let frame = LiveOutboundFrame.toolResponse(
                functionResponseId: call.id,
                name: call.name,
                response: response,
            )
            do {
                try await transport?.send(frame)
                #if DEBUG
                VoiceSessionLog.log("tool_response.sent", ["name": call.name])
                #endif
            } catch {
                Logger.voice.warning(
                    "live_tool_response_send_failed name=\(call.name, privacy: .public) error=\(error.localizedDescription, privacy: .private)",
                )
                #if DEBUG
                VoiceSessionLog.logError("tool_response.send_failed", error: error, ["name": call.name])
                #endif
            }
        }

        // After toolResponse, state STAYS in `.toolCalling` until the
        // next serverContent audio frame arrives — the state machine's
        // legal transitions forbid `.toolCalling → .thinking` (only
        // `.toolCalling → .modelSpeaking` is allowed). When Gemini
        // resumes its spoken response (sharp-edge #9: auto-continue
        // after toolResponse), `handleServerContent` advances
        // `.toolCalling → .modelSpeaking` on the first audio chunk.
        // Removing a prior premature `.toolCalling → .thinking` hop
        // that would have hit an assertionFailure in debug builds.
    }

    private func dispatchTool(_ call: LiveFunctionCall) async -> [String: Any] {
        switch call.name {
        case "substitution_check":
            return await dispatchSubstitution(call)
        case "start_timer":
            guard let secs = call.timerSeconds else {
                return ["ok": false, "error": "missing_seconds"]
            }
            let snapshot: CookModeViewModel.VoiceTimerSnapshot
            if let cb = onStartTimerRequested {
                // Await the start so the resulting snapshot reflects
                // the real on-screen CookTimer (NOT an LLM-guessed
                // state). The VM writes the CookTimer to Core Data
                // and schedules the UNNotificationRequest inside
                // `startTimerFromVoice`, so this await is the actual
                // "timer is live" fence.
                snapshot = await cb(secs, call.timerLabel)
            } else {
                snapshot = makeNoneTimerSnapshot()
            }
            var response = snapshotToDict(snapshot)
            response["ok"] = snapshot.state == .running || snapshot.state == .pending
            if !((response["ok"] as? Bool) ?? false) {
                response["error"] = "timer_not_started"
            }
            return response
        case "get_timer_status":
            let snapshot = onTimerQueryRequested?() ?? makeNoneTimerSnapshot()
            var response = snapshotToDict(snapshot)
            response["ok"] = true
            return response
        case "pause_timer":
            let snapshot: CookModeViewModel.VoiceTimerSnapshot
            if let cb = onTimerPauseRequested {
                snapshot = await cb()
            } else {
                snapshot = makeNoneTimerSnapshot()
            }
            var response = snapshotToDict(snapshot)
            response["ok"] = snapshot.state == .paused
            if snapshot.state != .paused {
                response["error"] = "no_running_timer"
            }
            return response
        case "resume_timer":
            let snapshot: CookModeViewModel.VoiceTimerSnapshot
            if let cb = onTimerResumeRequested {
                snapshot = await cb()
            } else {
                snapshot = makeNoneTimerSnapshot()
            }
            var response = snapshotToDict(snapshot)
            response["ok"] = snapshot.state == .running
            if snapshot.state != .running {
                response["error"] = "no_paused_timer"
            }
            return response
        case "cancel_timer":
            let snapshot: CookModeViewModel.VoiceTimerSnapshot
            if let cb = onTimerCancelRequested {
                snapshot = await cb()
            } else {
                snapshot = makeNoneTimerSnapshot()
            }
            var response = snapshotToDict(snapshot)
            response["ok"] = snapshot.state != .running && snapshot.state != .paused
            return response
        case "restart_timer":
            // Atomic cancel-then-start. `timerSeconds` may be nil — VM
            // reuses the existing timer's total duration in that case.
            // If no existing timer AND no seconds, VM returns a
            // .none/.cancelled snapshot and we map it to no_existing_timer.
            let snapshot: CookModeViewModel.VoiceTimerSnapshot
            if let cb = onTimerRestartRequested {
                snapshot = await cb(call.timerSeconds, call.timerLabel)
            } else {
                snapshot = makeNoneTimerSnapshot()
            }
            var response = snapshotToDict(snapshot)
            // P0-C (2026-04-23): check the VM's explicit restart bookkeeping
            // BEFORE relying on timer-active state. The prior check (just
            // `.running || .pending`) returned ok=true on a partial-cancel
            // failure because the STALE original timer was still running —
            // narrating "I restarted the timer" while the original alarm's
            // fire date stood. Device-reproduced 2026-04-23.
            //
            // `restartSucceeded == false` means the VM's cancel-before-start
            // loop couldn't drain the step-scoped active timers and
            // bailed rather than create a duplicate. `nil` defaults to
            // "no explicit signal, fall back to state check" for defensive
            // compatibility with callbacks that don't set the field.
            let restartSucceeded = snapshot.restartSucceeded ?? true
            let timerActive = snapshot.state == .running || snapshot.state == .pending
            let ok = restartSucceeded && timerActive
            response["ok"] = ok
            if !ok {
                if !restartSucceeded {
                    // Cancel loop failed — model should prompt user to
                    // explicitly cancel then start a fresh timer rather
                    // than retrying the restart blindly.
                    response["error"] = "cancel_failed"
                } else {
                    // No timer to restart + no seconds given → advise the
                    // model to suggest start_timer instead.
                    response["error"] = "no_existing_timer"
                }
            }
            return response
        case "set_step":
            // Generalized step navigation — forward OR backward. Accepts
            // a 1-indexed target step. VM clamps into range.
            #if DEBUG
            // Log the raw arg so we can see what the model actually
            // sent — `targetStepNumber` clamps <=0 to 1 and >=101 to
            // 100, so a user report of "step 1 doesn't work" would
            // otherwise hide the model's 0-indexed confusion.
            VoiceSessionLog.log("tool_args.set_step", [
                "step_number_raw": String(describing: call.args["step_number"] ?? "nil"),
                "target": call.targetStepNumber ?? -1,
            ])
            #endif
            guard let target1 = call.targetStepNumber else {
                return ["ok": false, "error": "invalid_step_number"]
            }
            onGoToStepRequested?(target1)
            return makeStepResponse()
        case "advance_step":
            // Legacy tool name (pre-v1.3.0 prompts). Kept as an alias
            // so in-flight sessions minted on v1.2.0 still work during
            // the rollout window. Always +1.
            onAdvanceStepRequested?()
            return makeStepResponse()
        default:
            Logger.voice.warning("live_unknown_tool name=\(call.name, privacy: .public)")
            return ["ok": false, "error": "unknown_tool"]
        }
    }

    /// Flatten a VoiceTimerSnapshot into the tool-response dict the
    /// model expects. Fields omitted when nil/zero so the dict stays
    /// compact.
    private func snapshotToDict(_ s: CookModeViewModel.VoiceTimerSnapshot) -> [String: Any] {
        var dict: [String: Any] = [
            "state": s.state.rawValue,
            "remaining_seconds": s.remainingSeconds,
        ]
        if s.totalSeconds > 0 {
            dict["total_seconds"] = s.totalSeconds
        }
        if let label = s.label, !label.isEmpty {
            dict["label"] = label
        }
        if let step = s.stepNumber {
            dict["step_number"] = step
        }
        return dict
    }

    /// Fallback used when a timer callback is unset. Indicates "no
    /// timer attached at all" rather than "timer exists but is idle".
    private func makeNoneTimerSnapshot() -> CookModeViewModel.VoiceTimerSnapshot {
        CookModeViewModel.VoiceTimerSnapshot(
            state: .none, remainingSeconds: 0, totalSeconds: 0, label: nil, stepNumber: nil,
        )
    }

    /// Build the standard tool-response dict describing the user's
    /// CURRENT step post-navigation. Shared by `set_step` and the
    /// legacy `advance_step` path so the model gets the same grounding
    /// either way. Returns `ok: true` always — the navigation itself
    /// is clamped to bounds by the VM, so even past-end requests
    /// produce a valid dict (`is_last_step: true`).
    ///
    /// The VM's handler is synchronous (MainActor + Core Data save),
    /// so `cookingSession.currentStepIndex` reflects the post-nav value
    /// by the time we read it here.
    private func makeStepResponse() -> [String: Any] {
        let newIdx = Int(cookingSession.currentStepIndex)
        let steps = cookingSession.recipePlan?.stepArray ?? []
        if steps.indices.contains(newIdx) {
            let newStep = steps[newIdx]
            return [
                "ok": true,
                "new_step_number": newIdx + 1,
                "new_step_text": Self.safeInstructionText(newStep.instructionText),
                "total_steps": steps.count,
                "is_last_step": newIdx == steps.count - 1,
            ]
        }
        return [
            "ok": true,
            "new_step_number": steps.count,
            "new_step_text": "(no further steps)",
            "total_steps": steps.count,
            "is_last_step": true,
        ]
    }

    private func dispatchSubstitution(_ call: LiveFunctionCall) async -> [String: Any] {
        // Route through AIDispatch.substitution. Backend enforces the
        // hard-rule validator identically to the sheet path (single
        // source of truth per CLAUDE.md §north-star constraint #5).
        //
        // Build full recipe + household context from the live cooking
        // session so the validator has everything it needs — same
        // shape the sheet sends. live_session_id correlation is wired
        // via `cookingSessionID` (paired with the mint's session_id
        // on the backend via ai_request_log metadata).

        // Generate the sub_event_id up-front so BOTH the requested fire
        // (below) AND the paired resolved fire (in the
        // .safe / .unsafe cases) carry the same ID, letting the
        // funnel join them without timestamp heuristics.
        let subEventID = UUID()
        let subEventIDString = subEventID.uuidString

        // C.5: fire the spec §15 `substitution_requested` event with
        // `invocation: "realtime_function_call"` so the rescue-usage
        // dashboard can distinguish voice-driven substitutions from
        // sheet-driven ones. Fires BEFORE the guard clauses below —
        // the model-intent-to-substitute signal is what matters for
        // funnel analysis, not whether the args parsed cleanly.
        onSubstitutionRequestedFromVoice?(subEventIDString)

        guard let missingIngredient = call.substitutionMissingIngredient,
              !missingIngredient.isEmpty
        else {
            #if DEBUG
            VoiceSessionLog.log("substitution.missing_args", ["tool": call.name])
            #endif
            return [
                "ok": false,
                "error": "missing_ingredient_required",
                "message": "Tell the user you need to know which ingredient is missing.",
            ]
        }
        let userProblem = call.substitutionUserProblem ?? "Out of \(missingIngredient)"

        guard let sessionID = cookingSession.id,
              let recipePlan = cookingSession.recipePlan,
              let recipePlanID = recipePlan.id
        else {
            Logger.voice.warning("live_substitution_missing_ids")
            return [
                "ok": false,
                "error": "session_state_invalid",
                "message": "Tell the user to use the Substitution Sheet.",
            ]
        }

        let steps = recipePlan.stepArray
        let currentIdx = Int(cookingSession.currentStepIndex)
        let remaining = recipePlan.ingredientArray.map { ing in
            SubstitutionRequest.RecipeContext.RemainingIngredient(
                displayName: ing.displayName ?? "",
                canonicalSlug: ing.canonicalIngredientSlug,
            )
        }
        let recipeContext = SubstitutionRequest.RecipeContext(
            title: recipePlan.title ?? "",
            currentStepNumber: max(1, currentIdx + 1),
            totalSteps: max(1, steps.count),
            remainingIngredients: remaining,
        )

        // Household context: pantry + dietary rules + equipment.
        // P2-I (2026-04-23): routed through the shared
        // `HouseholdProfile.voiceContextSnapshot()` seam. Prior inline
        // projection here accepted any pantry item with a non-empty
        // displayName — diverging from the mint + VM paths, which
        // required `userConfirmed && deletedAt == nil`. Unconfirmed
        // items could leak into the substitution validator. Canonical
        // filter now applies uniformly.
        let householdContext = SubstitutionRequest.HouseholdContext(
            snapshot: cookingSession.household?.voiceContextSnapshot() ?? .empty,
        )

        let request = SubstitutionRequest(
            subEventID: subEventID,
            cookingSessionID: sessionID,
            recipePlanID: recipePlanID,
            missingIngredient: SubstitutionRequest.MissingIngredient(
                displayName: missingIngredient,
                canonicalSlug: nil,
                amountText: nil,
            ),
            userProblem: userProblem,
            householdContext: householdContext,
            recipeContext: recipeContext,
        )

        #if DEBUG
        VoiceSessionLog.log("substitution.dispatch", [
            "missing": missingIngredient,
            "step": max(1, currentIdx + 1),
            "sub_event_id": subEventIDString,
        ])
        #endif

        do {
            let result = try await aiDispatch.substitution(request: request)
            switch result {
            case let .safe(_, text, amountConversion, reasoning, confidence, _):
                #if DEBUG
                VoiceSessionLog.log("substitution.safe", [
                    "confidence": confidence.rawValue,
                ])
                #endif
                // Voice has no user confirm step — a safe substitution
                // is auto-applied as the model speaks it. Fire
                // `substitution_accepted` so the voice rescue funnel
                // stays symmetric with the sheet path.
                onSubstitutionResolvedFromVoice?(true, subEventIDString)
                // Persist + mutate the recipe so the swap is visible to
                // every downstream consumer (substitution picker, the
                // next voice turn's remainingIngredients, grocery
                // export). Without this, "auto-applied" is a narration-
                // only claim that diverges from the persisted recipe.
                onSubstitutionAppliedFromVoice?(
                    subEventID, missingIngredient, text, amountConversion,
                )
                var response: [String: Any] = [
                    "ok": true,
                    "safe_to_use": true,
                    "substitution": text,
                    "reasoning": reasoning,
                    "confidence": confidence.rawValue,
                ]
                if let conv = amountConversion, !conv.isEmpty {
                    response["amount_conversion"] = conv
                }
                return response
            case let .unsafe(_, reason, message, _):
                #if DEBUG
                VoiceSessionLog.log("substitution.unsafe", ["reason": reason])
                #endif
                // Unsafe on voice = system refused to apply. Emit a
                // paired accepted=false so the funnel shows refusal
                // rate rather than silently dropping the pair.
                onSubstitutionResolvedFromVoice?(false, subEventIDString)
                return [
                    "ok": true,
                    "safe_to_use": false,
                    "reason": reason,
                    "message": message,
                ]
            }
        } catch {
            Logger.voice.warning(
                "live_substitution_failed error=\(error.localizedDescription, privacy: .private)",
            )
            #if DEBUG
            VoiceSessionLog.logError("substitution.upstream_failed", error: error)
            #endif
            return [
                "ok": false,
                "error": "upstream_failed",
                "message": "Tell the user substitution check failed and to tap the Substitution Sheet.",
            ]
        }
    }
}
