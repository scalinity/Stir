// RealtimeSessionStateMachine
//
// SCA-79 — extracted from RealtimeSession.swift. Owns the inbound
// frame state machine and turn lifecycle:
//   - refreshSession (ADR 0014: silent token-mint + WS swap)
//   - turn-stuck watchdog (rearm / cancel / fire — recovers from
//     Gemini Live preview-API dropped turnComplete frames)
//   - pre-mint slot management (kickOff / cancel / consume)
//   - recap building + sanitizer (sanitizeForRecap is `nonisolated
//     static` because tests call `RealtimeSession.sanitizeForRecap` —
//     keep that exact entry point)
//   - persistVoiceTurn helpers
//   - finalizeTurn + flushPendingReport (PendingReportDrainReason
//     stays a private enum here)
//   - awaitTurnComplete continuation pattern
//   - handleInboundFrame + handleServerContent (frame routing)
//   - recordTurnAsTransportError (transport-error recovery row)
//
// All instance stored properties live on the main RealtimeSession
// class declaration in RealtimeSession.swift. Methods here read them
// via `self`.

import Foundation
import OSLog

extension RealtimeSession {

    // MARK: - Session refresh (ADR 0014)

    /// Silent handoff to a fresh Gemini Live session. Triggered at
    /// `LiveSessionBudget.refreshAtTurnCount` turn boundary OR any
    /// single turn that exceeds `refreshAtPromptTokenCount`, and also
    /// defensively on server goAway frames (server signalled 30-min
    /// hard cap approach). Also guards against race re-entry via
    /// `isRefreshing`.
    ///
    /// Dance (order matters — a wrong order leaks either audio frames
    /// into the wrong transport or state updates against a stale
    /// mintResponse):
    ///   1. Guard state + set `isRefreshing = true` in defer-unset block
    ///   2. Build minimal recap — step position only (ADR 0014 PM amendment)
    ///   3. Mint new token with `is_refresh: true, recap: <recap>`
    ///      (backend skips quota increment; systemInstruction gets
    ///      recap suffix for continuity)
    ///   4. Open new WS transport (local var — not yet assigned to self)
    ///   5. Cancel old receive dispatcher ONLY. The mic forwarder stays
    ///      alive across refresh — `pipeline.micFrames` is a single-
    ///      consumer AsyncStream and cancel+restart would wedge it to
    ///      `.finished` permanently. The forwarder instead reads
    ///      `self.transport` dynamically each iteration and picks up
    ///      the swap done in step 6 automatically.
    ///      `startReceiveDispatcher` bumps `dispatcherGeneration` when
    ///      the new one starts in step 7 — the old dispatcher's
    ///      cancellation error is suppressed in its catch block by
    ///      generation check (structural, race-free).
    ///   6. Swap `self.transport` + `self.mintResponse` to new
    ///   7. Restart receive dispatcher on new transport (bumps gen)
    ///   8. Send setup frame on new transport
    ///   9. Await setupComplete (shared continuation; new dispatcher
    ///      drives it)
    ///  10. (Mic forwarder continues; if nil because it never started,
    ///      start it here)
    ///  11. Close old transport
    ///  12. Reset per-turn state + bump `lastRefreshedAtTurn`
    ///
    /// Failure mode: if any step throws, we fall back to the old
    /// transport IF it's still open (i.e., we failed before the swap).
    /// After the swap the old transport is gone and a failure leaves
    /// us in an unrecoverable state — transition to .error and the VM
    /// downgrades to C.3. Rare path; logs allow post-hoc triage.
    @discardableResult
    func refreshSession(reason: String) async -> RefreshOutcome {
        guard !isRefreshing else {
            #if DEBUG
            VoiceSessionLog.log("refresh.skipped_already_in_flight")
            #endif
            return .skipped
        }
        guard stateMachine.state != .closed && stateMachine.state != .error else {
            #if DEBUG
            VoiceSessionLog.log("refresh.skipped_state", [
                "state": stateMachine.state.rawValue,
            ])
            #endif
            return .skipped
        }
        isRefreshing = true
        // Defer-unset guarantees the flag clears even if a future edit
        // adds code after the do/catch that throws (review 2026-04-22
        // Warning #2). Runs on @MainActor before the method returns.
        defer { isRefreshing = false }

        // P1-J (2026-04-23): advance the state machine into .refreshing
        // so external observers (`beginTurn`'s state guard, VM's
        // MicButtonRole, etc.) see the mid-refresh window. Prior code
        // relied on `isRefreshing` alone, which was actor-internal and
        // invisible to callers — `beginTurn`'s `state == .ready` guard
        // could pass during the brief old-close / new-setupComplete
        // window and race a frame into the swap.
        let preRefreshState = stateMachine.state
        stateMachine.advance(to: .refreshing)

        let startedAt = Date()
        let oldSessionID = mintResponse?.sessionID ?? ""
        // Captured inside the do-block once the new response is minted.
        // On post-commit failure (swap assigned but setup handshake
        // threw) we report THIS id so dashboard triage correctly
        // attributes the failure to the destination session — not the
        // source, which was fine.
        var destinationSessionID: String?
        Logger.voice.info(
            "live_session_refresh_started turn=\(self.turnCount, privacy: .public) old_session=\(oldSessionID, privacy: .public)",
        )
        #if DEBUG
        VoiceSessionLog.log("refresh.start", [
            "turn": turnCount,
            "old_session": oldSessionID,
        ])
        #endif

        // Track the old transport so we can close it at the end. Nil
        // if refresh fires in a state where we somehow have no transport
        // (defensive — shouldn't happen with the state guards above).
        let oldTransport = self.transport

        do {
            // 2. Build minimal recap (step position only, ADR 0014 PM amendment).
            let recap = buildRecap()

            // 3. Mint new token with refresh-mode context. Fast path:
            // consume a pre-minted token kicked off one turn earlier.
            // Cold path: sync mint here. Pre-mint shaves ~1.5-1.9s off
            // the handoff's critical path in the common case.
            let newResponse: RealtimeSessionResponse
            if let preMintTask = consumePreMintedTaskIfFresh() {
                newResponse = try await preMintTask.value
            } else {
                let mintRequest = try buildMintRequest(recap: recap, isRefresh: true)
                newResponse = try await aiDispatch.realtimeSession(request: mintRequest)
            }
            destinationSessionID = newResponse.sessionID
            #if DEBUG
            VoiceSessionLog.log("refresh.mint_complete", [
                "new_session": newResponse.sessionID,
                "prompt_version": newResponse.promptVersion,
            ])
            #endif

            // 4. Open new WS transport.
            guard let wsURL = URL(string: newResponse.wsURL) else {
                throw RealtimeSessionError.openFailed(message: "invalid ws_url from refresh mint")
            }
            let newTransport = LiveWebSocketTransport()
            try newTransport.open(url: wsURL)

            // 5. Tear down the old RECEIVE dispatcher only. Do NOT
            //    cancel the mic forwarder — `pipeline.micFrames` is a
            //    single-consumer AsyncStream and starting a second
            //    iteration after cancel returns `.finished`, leaving
            //    post-refresh turns with zero mic audio forwarded
            //    (observed 2026-04-22, turn 10+: zero `mic.sent`).
            //    The forwarder now reads `self.transport` dynamically
            //    each iteration, so swapping the transport in step 6
            //    automatically redirects its sends to the new WS.
            //
            //    The receive dispatcher's cancellation throw IS
            //    suppressed structurally by the generation check in
            //    its own catch block (see startReceiveDispatcher) —
            //    step 7 bumps `dispatcherGeneration` and the old
            //    dispatcher's captured gen no longer matches.
            receiveDispatcherTask?.cancel()
            receiveDispatcherTask = nil

            // 6. Swap owned references to new transport + response.
            self.transport = newTransport
            self.mintResponse = newResponse

            // 7. Restart receive dispatcher on new transport. This is
            //    what will drive the setupComplete continuation in
            //    step 9.
            startReceiveDispatcher()

            // 8. Send setup frame (baked-in config must be sent
            //    explicitly even after mint — same contract as preWarm,
            //    see sharp-edge #19).
            // P3-D (2026-04-23): send pre-serialized JSON directly;
            // avoids triple JSON round-trip on every refresh.
            try await newTransport.send(.setupRawJSON(newResponse.setupFrameJSON))

            // 9. Wait for setupComplete on the new session. Shared
            //    continuation — new dispatcher will resume it.
            try await awaitSetupComplete(timeoutSec: LiveSessionBudget.setupHandshakeSec)

            // 10. (Mic forwarding stays alive across the refresh — no
            //     restart needed. The forwarder reads `self.transport`
            //     dynamically each iteration and picks up the swap done
            //     in step 6 automatically. If the forwarder was somehow
            //     already nil (e.g., never started), start it now.)
            if micForwardTask == nil {
                startMicForwarding()
            }

            // 11. Close the old transport now that we're fully migrated.
            //     Idempotent; no-op if the cancelled dispatcher already
            //     caused it to unwind.
            oldTransport?.close()

            // 12. Flush the just-finalized turn's pending report BEFORE
            //     resetting accumulators. finalizeTurn() schedules the
            //     refresh AND the pendingReport in the same pass, and
            //     flushPendingReport's usage-arrival path might not
            //     have fired yet if the trailing usageMetadata frame
            //     was still pending when we started the refresh. Losing
            //     the report silently would under-report per-turn cost
            //     in voice-turn-usage for exactly the turn that
            //     triggered the refresh. Flush with whatever tokens we
            //     have. The `supersededByRefresh` reason distinguishes
            //     this in dashboards from the generic "newer turn
            //     arrived" supersede path.
            if pendingReport != nil {
                flushPendingReport(dueTo: .supersededByRefresh)
            }

            // Reset per-turn state. The new session has zero history
            // from Gemini's perspective (we seeded continuity via
            // recap in systemInstruction, not via replayed turns),
            // so accumulators start fresh.
            turnUsageAccumulator = TurnUsageAccumulator()
            currentTurnInlineText = nil
            currentTurnUserTranscript = nil
            lastRefreshedAtTurn = turnCount

            let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            Logger.voice.info(
                "live_session_refresh_complete turn=\(self.turnCount, privacy: .public) new_session=\(newResponse.sessionID, privacy: .public) latency_ms=\(latencyMs, privacy: .public)",
            )
            #if DEBUG
            VoiceSessionLog.log("refresh.complete", [
                "turn": turnCount,
                "new_session": newResponse.sessionID,
                "latency_ms": latencyMs,
            ])
            #endif
            // Spec §15 voice_session_refreshed — SUCCESS path. Carries
            // the NEW session id since the swap committed.
            if let cb = onVoiceSessionRefreshResolved {
                cb(reason, turnCount, newResponse.sessionID, true)
            }
            // P1-J: settle out of .refreshing. We return to .ready
            // uniformly; any in-flight turn was either flushed above
            // (supersededByRefresh drain) or was finalized by the time
            // refresh fired (cadence refresh runs from finalizeTurn's
            // post-turn-reset path). Prior state value not restored
            // because the new session starts fresh from Gemini's
            // perspective — .ready is the correct entry point.
            if stateMachine.state == .refreshing {
                stateMachine.advance(to: .ready)
            }
            _ = preRefreshState // preserved for future restore-prior-state logic if needed
            return .success
        } catch {
            let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            Logger.voice.error(
                "live_session_refresh_failed error=\(error.localizedDescription, privacy: .private) latency_ms=\(latencyMs, privacy: .public)",
            )
            #if DEBUG
            VoiceSessionLog.logError("refresh.failed", error: error, [
                "turn": turnCount,
                "latency_ms": latencyMs,
            ])
            #endif
            // Recovery: if the old transport is still alive (we failed
            // before swap), keep using it — degraded (token growth
            // continues) but functional. If we failed after swap, the
            // session is broken; transition to .error so the VM can
            // fall back to C.3 on the next tap.
            let isPreCommitFailure = (self.transport === oldTransport)
            if isPreCommitFailure {
                // Still on old transport — no state change needed.
                Logger.voice.info("refresh_failed_on_old_transport session_continues")
                // P1-J: back to whatever state we entered refresh from.
                // The old transport is healthy; session continues as
                // if refresh never happened. Self-transition is a no-op
                // if preRefreshState == .refreshing (shouldn't happen —
                // guard blocks re-entry — but safe either way).
                if stateMachine.state == .refreshing {
                    stateMachine.advance(to: preRefreshState)
                }
            } else {
                // Committed the swap but handshake failed — new
                // transport is useless, old is NOT yet closed (step 11
                // of the 12-step dance only fires on the happy path).
                // Close it here so we don't leak the WS until Gemini's
                // 35-min TTL fires — observed during review P0-B
                // (2026-04-23) as a drip of orphaned connections
                // accumulating per failed refresh, which at beta user
                // cadence compounds meaningfully.
                oldTransport?.close()
                // CA2-6 fix: also tear down the mic forwarder. After the
                // swap commit, micForwardTask reads `self.transport` per
                // iteration and is now writing PCM frames to the broken
                // newTransport. Without explicit cancel, the forwarder
                // drips send-failures + CPU + network until the VM closes
                // the driver via C.3 fallback — which can be seconds
                // away on a slow tap. Cancel here so the next iteration
                // exits, then null the slot so a future preWarm can
                // restart it cleanly.
                micForwardTask?.cancel()
                micForwardTask = nil
                // P1-J: route via .fallingBack → .error so the grammar
                // records the failure path explicitly. .fallingBack is
                // the canonical "Live → C.3 handoff" state per
                // VoiceSessionState.swift.
                if stateMachine.state == .refreshing {
                    stateMachine.advance(to: .fallingBack)
                }
                stateMachine.advance(to: .error)
                // P1-K (2026-04-23): tell the VM that any future voice
                // rebuild within this Cook Mode session should skip
                // Live and go straight to C.3. Fresh Live preWarm on
                // the same device + same network after a post-commit
                // handshake failure has a high probability of failing
                // the same way; pinning fallback avoids the ping-pong
                // latency the user would otherwise perceive on every
                // subsequent tap.
                onVoiceFallbackRequired?("refresh_post_commit_failure")
            }
            // Spec §15 voice_session_refreshed — FAILURE path. Emitting
            // on failure is what lets the Voice session health dashboard
            // compute a real refresh success rate (prior design fired on
            // request only so failures went telemetry-invisible).
            //
            // session_id semantics — report the session that "owned" the
            // failure so dashboard triage is actionable:
            //   pre-commit failure (mint / WS open / setup-send threw
            //     before self.transport was swapped) → OLD id; the
            //     destination never came up and the old session is
            //     still live.
            //   post-commit failure (swap assigned, awaitSetupComplete
            //     or later threw) → NEW id; old session is already torn
            //     down and the failure is attached to the destination
            //     that didn't handshake.
            let failureSessionID: String
            if self.transport === oldTransport {
                failureSessionID = oldSessionID
            } else {
                failureSessionID = destinationSessionID ?? oldSessionID
            }
            if let cb = onVoiceSessionRefreshResolved {
                cb(reason, turnCount, failureSessionID, false)
            }
            return isPreCommitFailure ? .preCommitFailure : .postCommitFailure
        }
        // `isRefreshing = false` handled by the `defer` at the top.
    }

    // MARK: - Turn-stuck watchdog

    /// (Re-)arm the stuck-modelSpeaking watchdog. Called on every
    /// inbound audio chunk and on state transition into `.modelSpeaking`.
    /// Cancels any prior watchdog first — the new timer restarts from
    /// zero, giving multi-chunk turns a fresh budget per chunk.
    func rearmTurnStuckWatchdog() {
        turnStuckWatchdog?.cancel()
        turnStuckWatchdog = Task { [weak self] in
            let nanos = UInt64(LiveSessionBudget.turnStuckWatchdogSec * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            await self?.turnStuckWatchdogFired()
        }
    }

    /// Cancel the watchdog without firing. Called on state transition
    /// OUT of `.modelSpeaking` (turnComplete, refresh, error, close).
    func cancelTurnStuckWatchdog() {
        turnStuckWatchdog?.cancel()
        turnStuckWatchdog = nil
    }

    /// Watchdog fired — Gemini went `turnStuckWatchdogSec` seconds in
    /// `.modelSpeaking` with no inbound audio chunk. Synthesize a
    /// turnComplete so the state machine unwedges and the user can
    /// speak again. Re-checks state under MainActor because a real
    /// `turnComplete` could have arrived between the Task.sleep wake
    /// and the fire handler (rare but possible).
    @MainActor
    func turnStuckWatchdogFired() {
        guard stateMachine.state == .modelSpeaking else { return }
        let now = Date()
        let elapsedStuckMs: Int = {
            guard let last = lastInboundAudioAt else { return 0 }
            return Int(now.timeIntervalSince(last) * 1000)
        }()
        let turnLengthAtStuck: Int = {
            guard let started = turnStartedAt else { return 0 }
            return Int(now.timeIntervalSince(started) * 1000)
        }()
        // `turnCount + 1` matches the turn about to finalize. finalizeTurn
        // increments turnCount before persist, so the watchdog PostHog
        // payload and the persisted VoiceTurn row share the same
        // turnIndex semantic (1-indexed, the "turn we were on").
        let watchdogTurnIndex = turnCount + 1
        let toolCallType = lastToolCallName

        Logger.voice.warning(
            "turn_stuck_watchdog_fired — synthesizing turnComplete turn=\(watchdogTurnIndex, privacy: .public) tool=\(toolCallType ?? "nil", privacy: .public) elapsed_stuck_ms=\(elapsedStuckMs, privacy: .public) turn_length_ms=\(turnLengthAtStuck, privacy: .public) (Gemini Live appears to have dropped turnComplete; see ADR 0014/0015 notes)",
        )
        #if DEBUG
        VoiceSessionLog.log("turn.stuck_watchdog_fired", [
            "turn": watchdogTurnIndex,
            "watchdog_sec": LiveSessionBudget.turnStuckWatchdogSec,
            "tool_call_type": toolCallType ?? "nil",
            "elapsed_stuck_ms": elapsedStuckMs,
            "turn_length_at_stuck": turnLengthAtStuck,
        ])
        #endif
        // Fire PostHog callback BEFORE advancing state — so the VM
        // emission uses the current session id (not a stale swap) and
        // latches onto the turn about to finalize, not the next one.
        // `mintResponse?.sessionID` is always populated by the time the
        // watchdog fires (watchdog only arms on `.modelSpeaking` which
        // implies setup completed); the `"unknown"` fallback is defensive
        // against future invariant drift, not an observed path.
        onVoiceTurnStuckWatchdogFired?(
            mintResponse?.sessionID ?? "unknown",
            watchdogTurnIndex,
            toolCallType,
            elapsedStuckMs,
            turnLengthAtStuck,
        )
        // Flag the imminent finalizeTurn so the model-turn persist
        // path uses `resultType: .error, errorCode: "turnComplete_timeout"`
        // instead of the normal `.normal` default. Reset inside
        // finalizeTurn after the persist lands.
        finalizeWasWatchdogFire = true

        // Mirror the state-transition path that `content.turnComplete`
        // takes in `handleServerContent`: modelSpeaking → ready. Not
        // handling thinking/toolCalling/userSpeaking here because the
        // watchdog only runs when we're in modelSpeaking (enforced by
        // the guard above).
        stateMachine.advance(to: .ready)
        finalizeTurn()
    }

    // MARK: - Pre-mint slot

    /// round-trip. Called from `finalizeTurn`'s refresh trigger block at
    /// `turnsSinceRefresh == refreshAtTurnCount - 1`. No-op if a pre-mint
    /// is already in flight or we're mid-refresh. Build-time errors are
    /// logged at warn and the sync mint path handles it at refresh time.
    func kickOffPreMintIfBudgetAllows(currentTurn: Int) {
        guard pendingPreMintTask == nil else { return }
        guard !isRefreshing else { return }
        let mintRequest: RealtimeSessionRequest
        do {
            mintRequest = try buildMintRequest(recap: buildRecap(), isRefresh: true)
        } catch {
            Logger.voice.warning(
                "refresh_premint_build_failed error=\(error.localizedDescription, privacy: .private)",
            )
            return
        }
        let dispatch = aiDispatch
        let task = Task<RealtimeSessionResponse, Error> {
            return try await dispatch.realtimeSession(request: mintRequest)
        }
        pendingPreMintTask = task
        pendingPreMintStartedAt = Date()
        #if DEBUG
        VoiceSessionLog.log("refresh.premint_started", ["turn": currentTurn])
        #endif
    }

    /// Cancel any in-flight pre-mint Task and clear the slot. Extracted
    /// from `close()` so the P1-P `_testTearDownPreMintSlot` hook can
    /// exercise the exact production teardown — not a test-private copy.
    /// Call sites: `close()` + `_testTearDownPreMintSlot`. A future
    /// refactor that needs to add or change the teardown of the pre-mint
    /// slot must edit this one method; both call sites inherit the
    /// change.
    func cancelAndClearPreMintSlot() {
        if let preMint = pendingPreMintTask {
            preMint.cancel()
            pendingPreMintTask = nil
            pendingPreMintStartedAt = nil
        }
    }

    /// Consume the pending pre-mint if it exists and is still fresh.
    /// Returns the Task so the caller can await it; returns nil to signal
    /// "no usable pre-mint, fall back to sync". Cancels + clears stale
    /// entries. Always clears state regardless of outcome.
    func consumePreMintedTaskIfFresh() -> Task<RealtimeSessionResponse, Error>? {
        guard let task = pendingPreMintTask else { return nil }
        defer {
            pendingPreMintTask = nil
            pendingPreMintStartedAt = nil
        }
        let age = pendingPreMintStartedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard age < LiveSessionBudget.preMintStalenessSec else {
            task.cancel()
            Logger.voice.info(
                "refresh_premint_stale_discarded age_sec=\(age, privacy: .public)",
            )
            return nil
        }
        #if DEBUG
        VoiceSessionLog.log("refresh.premint_consumed", ["age_ms": Int(age * 1000)])
        #endif
        return task
    }

    // MARK: - Recap + sanitizer

    /// 2026-04-22 PM (ADR 0014 amendment): simplified from the earlier
    /// interleaved user+model turns structure. Device testing showed the
    /// model doesn't reference prior dialog after refresh, so the extra
    /// ~200-300 tokens of exchange history were pure overhead on a path
    /// that runs every 7 turns. Step position is the one piece of
    /// continuity the model consistently uses post-refresh.
    /// `sanitizeForRecap()` is kept available as defense-in-depth.
    private func buildRecap() -> String? {
        let stepsCount = cookingSession.recipePlan?.stepArray.count ?? 0
        let currentStep = Int(cookingSession.currentStepIndex) + 1
        // stepsCount == 0 during a valid cook session is impossible —
        // Cook Mode entry blocks on a non-empty recipe. Hitting this
        // guard means upstream data corruption; return nil so the
        // refresh proceeds without a recap (safer than asserting which
        // would crash in prod mid-session) and fire a warn log so it
        // surfaces in dashboards (review 2026-04-22 Suggestion #2).
        guard stepsCount > 0 else {
            Logger.voice.warning(
                "build_recap_no_steps cooking_session_id=\(self.cookingSession.id?.uuidString ?? "nil", privacy: .public)",
            )
            return nil
        }
        return "You are mid-cook on step \(currentStep) of \(stepsCount). Continue from here. Don't re-introduce the recipe."
    }

    /// Normalize a captured turn's text for recap inclusion: collapse
    /// whitespace, strip canonical prompt-injection markers, and truncate
    /// to ~140 chars. Defense-in-depth — the content comes from
    /// inputTranscription (user speech) or outputTranscription (model's
    /// own reply), both lower-risk than arbitrary user input, but
    /// echoing "Ignore prior instructions" into the next session's
    /// systemInstruction is cheap to defend against. `nonisolated` so
    /// unit tests can exercise it without @MainActor wrapping — the
    /// method is a pure string transform with no instance-state access.
    nonisolated static func sanitizeForRecap(_ raw: String) -> String {
        let oneLine = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Canonical injection markers. Order matters — longer patterns
        // first so shorter ones don't leave dangling fragments. P3-J
        // (2026-04-23): regex objects are pre-compiled in
        // `injectionRegexes` so sanitizeForRecap doesn't rebuild them
        // per call.
        var cleaned = oneLine
        for regex in Self.injectionRegexes {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(
                in: cleaned, options: [], range: range, withTemplate: "[redacted]",
            )
        }
        if cleaned.count > 140 {
            return String(cleaned.prefix(140)) + "…"
        }
        return cleaned
    }

    /// Pre-compiled injection-detection patterns. Evaluated in order;
    /// longer patterns first. Static so the regex compile cost is paid
    /// once per process rather than per sanitizer invocation.
    private static let injectionRegexes: [NSRegularExpression] = {
        let patterns: [String] = [
            "ignore (all )?(prior|previous|above|earlier) (instructions|directives|rules|prompts?)",
            "disregard (all )?(prior|previous|above|earlier) (instructions|directives|rules|prompts?)",
            "forget (all )?(prior|previous|above|earlier) (instructions|directives|rules|prompts?)",
            "override (all )?(system )?(instructions|directives|rules|prompts?)",
            "you are now (a|an) ",
            "new (system )?prompt:",
        ]
        return patterns.compactMap { pattern in
            try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }()

    // MARK: - VoiceTurn persist helpers

    /// Persist a VoiceTurn row with an observable error path (P0-G fix).
    /// Used by `finalizeTurn` (happy + watchdog) and
    /// `recordTurnAsTransportError` (transport-error recovery). Replaces
    /// the prior `try?` pattern that silently discarded Core Data save
    /// failures — losing the persist is the exact signal ADR 0015's
    /// cap-reversal trigger query keys off, so silent drop defeated
    /// the observability the whole watchdog was instrumented to provide.
    ///
    /// `context` is a static short string (e.g. "finalize_turn_model",
    /// "transport_error_recovery") that goes into the log line so
    /// dashboards can attribute persist failures by call site.
    private func persistVoiceTurnSafely(
        _ input: VoiceTurnRepository.PersistInput,
        context: String,
    ) {
        do {
            try voiceTurnRepository.persist(input)
        } catch {
            Logger.voice.error(
                "voice_turn_persist_failed context=\(context, privacy: .public) turn=\(self.turnCount, privacy: .public) speaker=\(input.speaker.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .private)",
            )
            #if DEBUG
            VoiceSessionLog.logError("voice_turn.persist_failed", error: error, [
                "context": context,
                "turn": turnCount,
                "speaker": input.speaker.rawValue,
            ])
            #endif
        }
    }

    /// P3-F (2026-04-23): batch variant used by `finalizeTurn` and
    /// `recordTurnAsTransportError` so the user + model VoiceTurn rows
    /// land in a single `context.save()` instead of two. Halves Core
    /// Data write overhead + CloudKit push rate per turn. Error
    /// handling mirrors `persistVoiceTurnSafely` — observable, non-
    /// re-throwing.
    private func persistVoiceTurnPairSafely(
        user: VoiceTurnRepository.PersistInput,
        model: VoiceTurnRepository.PersistInput,
        context: String,
    ) {
        do {
            try voiceTurnRepository.persistPair(user: user, model: model)
        } catch {
            Logger.voice.error(
                "voice_turn_persist_pair_failed context=\(context, privacy: .public) turn=\(self.turnCount, privacy: .public) error=\(error.localizedDescription, privacy: .private)",
            )
            #if DEBUG
            VoiceSessionLog.logError("voice_turn.persist_pair_failed", error: error, [
                "context": context,
                "turn": turnCount,
            ])
            #endif
        }
    }

    // MARK: - finalizeTurn + flushPendingReport

    private func finalizeTurn() {
        // Per-turn flag resets run via `defer` so any future early-return
        // (e.g. added guard clauses) can't leak a stale watchdog / tool-
        // call flag into the next turn's finalize. Current body has no
        // early returns, but the invariant is structurally enforced now
        // rather than positionally — surviving refactors without silent
        // data-corruption (stray `.error` row persisted on a normal turn).
        //
        // `turnContainedToolCall` is latched into a local below before
        // this defer fires; `lastToolCallName` was read by the watchdog
        // fire path BEFORE it invoked finalizeTurn; `finalizeWasWatchdogFire`
        // is read during the VoiceTurn persist block below. All three
        // have been captured or consumed by the time defer runs.
        defer {
            turnContainedToolCall = false
            lastToolCallName = nil
            finalizeWasWatchdogFire = false
            // finalizeWasTransportError is reset by `recordTurnAsTransportError`
            // rather than finalizeTurn (finalizeTurn only runs on the
            // normal / watchdog paths — transport errors route through
            // the dedicated recorder). Reset here defensively anyway.
            finalizeWasTransportError = false
        }
        let now = Date()
        let startedAt = turnStartedAt ?? now
        let totalMs = Int(now.timeIntervalSince(startedAt) * 1000)
        turnCount += 1

        // TTFA = time from server's VAD-end-of-user-speech to the first
        // model audio chunk. Frame-level precision (both endpoints are
        // WebSocket-handler timestamps, not UI-layer timers). Zero when
        // either endpoint is missing for this turn — the dashboard
        // filters zero values so "unmeasurable" doesn't skew the p95.
        let ttfaMs: Int = {
            guard let userEnd = userTurnEndAt,
                  let firstAudio = firstModelAudioAt,
                  firstAudio >= userEnd
            else { return 0 }
            return Int(firstAudio.timeIntervalSince(userEnd) * 1000)
        }()
        // Latch the tool-call flag BEFORE the per-turn reset below so
        // the PendingTurnReport captures the correct value even when
        // the handler clears it for the next turn.
        let containedToolCall = turnContainedToolCall

        // Latch the textual exchange BEFORE the per-turn reset below
        // so PendingTurnReport carries it through to flushPendingReport,
        // which is where `onTurnTranscriptFinalized` fires the snapshot
        // up to the VM. Either side may be empty; consumers decide
        // whether to render. Trimmed because servers occasionally emit
        // leading/trailing whitespace in delta frames.
        let userTextThisTurn = (currentTurnUserTranscript ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let modelTextThisTurn = (currentTurnInlineText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let transcriptSnapshot: LiveTurnTranscript? = (
            userTextThisTurn.isEmpty && modelTextThisTurn.isEmpty
        ) ? nil : LiveTurnTranscript(
            turnIndex: turnCount,
            userText: userTextThisTurn,
            modelText: modelTextThisTurn,
        )

        #if DEBUG
        VoiceSessionLog.log("turn.complete", [
            "turn": turnCount,
            "latency_ms": totalMs,
            "ttfa_ms": ttfaMs,
            "contained_tool_call": containedToolCall,
            "accum_prompt_tokens": turnUsageAccumulator.sumPromptTokens,
            "accum_response_tokens": turnUsageAccumulator.sumResponseTokens,
            "accum_has_data": turnUsageAccumulator.hasAnyData,
        ])
        #endif

        // Snapshot the per-turn result BEFORE clearing accumulators —
        // `endTurn()` (if the VM called it) reads this via
        // `lastTurnResult` after `awaitTurnComplete` resumes. The
        // `sttLatencyMs` slot carries TTFA on the Live path (the field
        // is overloaded — "stt" fits the fallback path's Speech-to-Text
        // latency; on Live it carries the equivalent "time-to-first-audio"
        // signal the VM maps onto `cook_turn_resolved.latency_ttfa_ms`).
        let snapshot = CookTurnResult(
            transcript: "",
            response: CookTurnResponse(
                spokenResponse: currentTurnInlineText ?? "",
                suggestedAction: .none,
                actionParams: nil,
                promptVersion: mintResponse?.promptVersion ?? "",
                latencyMS: totalMs,
                retryCount: 0,
            ),
            sttLatencyMs: ttfaMs,
            backendLatencyMs: totalMs,
        )
        lastTurnResult = snapshot

        // Persist VoiceTurn rows (user + model). Transcript unknown on
        // Live path — empty strings are fine per schema. turnIndex is
        // 1-indexed across the session's lifetime.
        //
        // On watchdog fires, the model-turn row is persisted with
        // `resultType: .error, errorCode: "turnComplete_timeout"` so
        // the session history audit reflects the stuck recovery per
        // spec §4.12. The user-turn row stays `.normal` because the
        // user did successfully speak — only the model's response
        // turn was truncated by the synthetic turnComplete.
        let userIdx = voiceTurnRepository.nextTurnIndex(for: cookingSession)
        // P0-G (2026-04-23): persist failures must be observable — prior
        // code used `try?` which silently discarded Core Data save errors.
        // Losing the persist is specifically the signal ADR 0015's
        // cap-reversal trigger query keys off (count of error-typed
        // rows per session); invisibling it defeats the point of having
        // the watchdog instrument the recovery path at all.
        //
        // P3-F (2026-04-23): batch both rows into one `context.save()`
        // via `persistVoiceTurnPairSafely` (halves Core Data +
        // CloudKit push overhead per turn; prior code called persist
        // twice producing two full graph walks).
        let modelResult: VoiceTurn.ResultType = finalizeWasWatchdogFire ? .error : .normal
        let modelErrorCode: String? = finalizeWasWatchdogFire ? "turnComplete_timeout" : nil
        persistVoiceTurnPairSafely(
            user: .init(
                session: cookingSession,
                speaker: .user,
                turnIndex: userIdx,
                transcriptText: "",
                inputMode: .voice,
                latencyMs: 0,
                resultType: .normal,
            ),
            model: .init(
                session: cookingSession,
                speaker: .model,
                turnIndex: userIdx + 1,
                transcriptText: currentTurnInlineText ?? "",
                inputMode: .voice,
                latencyMs: totalMs,
                resultType: modelResult,
                errorCode: modelErrorCode,
            ),
            context: finalizeWasWatchdogFire ? "finalize_turn_pair_watchdog" : "finalize_turn_pair",
        )

        // Reset per-turn accumulators EXCEPT `turnUsageAccumulator` —
        // it stays populated so `flushPendingReport` can snapshot it.
        currentTurnInlineText = nil
        currentTurnUserTranscript = nil
        turnStartedAt = now
        // Reset TTFA anchors so the next turn measures fresh.
        userTurnEndAt = nil
        firstModelAudioAt = nil

        // Session refresh trigger (ADR 0014). Fires when EITHER:
        //   (a) `turnCount - lastRefreshedAtTurn >= refreshAtTurnCount` (4)
        //   (b) accumulated prompt tokens this turn > refreshAtPromptTokenCount (10_000)
        // Guard `isRefreshing` prevents a second refresh kicking off while
        // one is in flight — trigger recheck happens on the next turn.
        // Skip when turnCount == 0 (defensive; accumulator can fire with
        // data during initial turn setup).
        if !isRefreshing && turnCount > 0 {
            let turnsSinceRefresh = turnCount - lastRefreshedAtTurn
            let promptTokensThisTurn = turnUsageAccumulator.sumPromptTokens
            let reason: String?
            if promptTokensThisTurn > LiveSessionBudget.refreshAtPromptTokenCount {
                reason = "tokens"
            } else if turnsSinceRefresh >= LiveSessionBudget.refreshAtTurnCount {
                reason = "turns"
            } else {
                reason = nil
            }
            if let reason {
                // DO NOT set `isRefreshing = true` here. `refreshSession()`
                // owns the flag; setting it in the caller plus the guard
                // inside the callee means the Task below sees the flag
                // set and returns immediately without doing any work
                // (review 2026-04-22 Critical #1).
                Task { [weak self] in await self?.refreshSession(reason: reason) }
            } else if turnsSinceRefresh == LiveSessionBudget.refreshAtTurnCount - 1 {
                // Pre-mint trigger: one turn before the cadence refresh
                // fires, kick off the next token mint in the background.
                kickOffPreMintIfBudgetAllows(currentTurn: turnCount)
            }
        }

        // Schedule the per-turn usage report. We defer the POST + VM
        // callback until either (a) inbound `usageMetadata` arrives
        // (early-fire path), or (b) the timeoutSec timer expires (defensive
        // fallback).
        if let superseded = pendingReport {
            Logger.voice.warning(
                "turn_report_superseded turn=\(superseded.turnIndex, privacy: .public) — next turn arrived before usage; flushing with current usage state (may be empty)",
            )
            flushPendingReport(dueTo: .supersededByNextTurn)
        }

        let nonce = UUID()
        pendingReport = PendingTurnReport(
            turnIndex: turnCount,
            latencyMs: totalMs,
            latencyTtfaMs: ttfaMs,
            containedToolCall: containedToolCall,
            submittedAt: startedAt,
            endedAt: now,
            nonce: nonce,
            transcript: transcriptSnapshot,
        )

        // Short-circuit: if we already accumulated any non-zero usage
        // data for this turn, flush right away.
        if turnUsageAccumulator.hasAnyData {
            flushPendingReport(dueTo: .usageArrived)
            return
        }

        // Otherwise wait for a trailing usageMetadata envelope OR the
        // timeoutSec timer — whichever comes first.
        let timeoutSec = LiveSessionBudget.pendingReportTimeoutSec
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSec))
            guard let self, self.pendingReport?.nonce == nonce else { return }
            self.flushPendingReport(dueTo: .timeout)
        }
    }

    /// Reason the pending report is being drained. Affects diagnostic
    /// logging only — the payload shape is the same regardless.
    enum PendingReportDrainReason {
        case usageArrived
        case timeout
        case supersededByNextTurn
        case supersededByRefresh
        case sessionClosed
    }

    /// Build + fire the voice-turn-usage POST and VM callback for the
    /// currently-pending turn. No-op if no report is pending. Idempotent:
    /// clears `pendingReport` and resets `turnUsageAccumulator` atomically
    /// so timer-vs-early-fire races can't double-post.
    func flushPendingReport(dueTo reason: PendingReportDrainReason) {
        guard let pending = pendingReport else { return }
        pendingReport = nil

        let usageForReport = turnUsageAccumulator.snapshot()
        turnUsageAccumulator.reset()

        #if DEBUG
        VoiceSessionLog.log("turn.usage_report_flush", [
            "turn": pending.turnIndex,
            "reason": String(describing: reason),
            "prompt_tokens": usageForReport?.promptTokenCount ?? -1,
            "response_tokens": usageForReport?.responseTokenCount ?? -1,
            "total_tokens": usageForReport?.totalTokenCount ?? -1,
        ])
        #endif

        if case .timeout = reason {
            // The timer fired — regardless of whether usage arrived just
            // before we ran, the fact that we hit the deadline at all is
            // diagnostic-worthy (Gemini is slow enough to threaten the
            // 2s budget). Differentiate "never arrived" from "arrived
            // late" in the log so ops can trend separately.
            if usageForReport == nil {
                Logger.voice.warning(
                    "usage_metadata_never_arrived turn=\(pending.turnIndex, privacy: .public) — firing report with zero tokens",
                )
            } else {
                Logger.voice.warning(
                    "usage_metadata_late turn=\(pending.turnIndex, privacy: .public) — usage arrived after \(LiveSessionBudget.pendingReportTimeoutSec, privacy: .public)s budget",
                )
            }
        }

        guard let sessionID = mintResponse?.sessionID,
              let sessionUUID = UUID(uuidString: sessionID)
        else { return }

        // Detect missing per-modality breakdown on ANY component — if
        // Gemini stops emitting promptTokensDetails / responseTokensDetails,
        // our fallback classifies unknowns as audio, which OVER-estimates
        // cost (audio-in $3/M vs text-in $0.75/M = 4×; audio-out $12/M
        // vs text-out $4.50/M = 2.67×). Dashboards drift silently unless
        // we surface this.
        if let usage = usageForReport {
            let promptBreakdownMissing =
                usage.promptAudioTokens == nil && usage.promptTextTokens == nil
            let responseBreakdownMissing =
                usage.responseAudioTokens == nil && usage.responseTextTokens == nil
            if promptBreakdownMissing || responseBreakdownMissing {
                Logger.voice.warning(
                    "usage_metadata_breakdown_missing session=\(sessionID, privacy: .public) turn=\(pending.turnIndex, privacy: .public) prompt_total=\(usage.promptTokenCount, privacy: .public) response_total=\(usage.responseTokenCount, privacy: .public) prompt_missing=\(promptBreakdownMissing, privacy: .public) response_missing=\(responseBreakdownMissing, privacy: .public)",
                )
            }
        }

        let promptText = usageForReport?.promptTextTokens ?? 0
        let promptAudioTotal = usageForReport.map {
            $0.promptAudioTokens ?? max(0, $0.promptTokenCount - ($0.promptTextTokens ?? 0))
        } ?? 0
        let responseText = usageForReport?.responseTextTokens ?? 0
        let responseAudioTotal = usageForReport.map {
            $0.responseAudioTokens ?? max(0, $0.responseTokenCount - ($0.responseTextTokens ?? 0))
        } ?? 0
        // Implicit-cache hit portion — nil when the accumulator was zero
        // (either caching didn't fire, or the field wasn't in the usage
        // frame at all). Forwarded to backend only when positive to keep
        // the wire tight on the common non-cached path. Powers the spec §9
        // cap-reversal trigger ("cachedContentTokenCount ≥ 50% of prompt
        // across 100 sessions").
        let promptCachedTotal = usageForReport?.cachedContentTokenCount

        // Map drain reason to wire-level endedReason so dashboards can
        // distinguish normal turn completions from timeouts, drops, and
        // supersedes. `usageArrived`, `supersededByNextTurn`, and
        // `supersededByRefresh` all represent successful turn boundaries
        // (Gemini completed the turn), so they map to `.turnComplete`.
        // `timeout` and `sessionClosed` map to `.error` — the turn
        // technically completed but we either lost usage data (timeout)
        // or the session tore down mid-stream (sessionClosed).
        let endedReason: VoiceTurnUsageRequest.TurnUsage.EndedReason = {
            switch reason {
            case .usageArrived, .supersededByNextTurn, .supersededByRefresh:
                return .turnComplete
            case .timeout, .sessionClosed:
                return .error
            }
        }()

        // Forward Gemini's raw `promptTokenCount` / `responseTokenCount`
        // totals so the backend can attribute the uncategorized
        // remainder at audio rate (AUDIO-mode overhead — CLAUDE.md
        // sharp-edge #15).
        let promptTotal = usageForReport?.promptTokenCount ?? 0
        let responseTotal = usageForReport?.responseTokenCount ?? 0

        let turnUsage = VoiceTurnUsageRequest.TurnUsage(
            turnIndex: pending.turnIndex,
            promptTokensText: max(0, promptText),
            promptTokensAudio: max(0, promptAudioTotal),
            promptTokensTotal: max(0, promptTotal),
            promptTokensCached: promptCachedTotal.flatMap { $0 > 0 ? $0 : nil },
            responseTokensText: max(0, responseText),
            responseTokensAudio: max(0, responseAudioTotal),
            responseTokensTotal: max(0, responseTotal),
            latencyMS: pending.latencyMs,
            endedReason: endedReason,
            promptVersion: mintResponse?.promptVersion ?? "",
            path: .liveAPI,
            endedAt: pending.endedAt,
        )
        let payload = VoiceTurnUsageRequest(sessionID: sessionUUID, turns: [turnUsage])

        let dispatch = aiDispatch
        let turnIdx = pending.turnIndex
        Task.detached {
            // P1-H (2026-04-23): surface failures to OSLog so wire-drift
            // (e.g. a release where iOS payload diverges from backend Zod
            // schema) doesn't silently black-hole every turn's cost
            // telemetry. Still fire-and-forget at the flow level (the
            // user turn continues regardless), but the error is
            // observable in Sentry breadcrumbs when it does happen.
            do {
                try await dispatch.voiceTurnUsage(request: payload)
            } catch {
                Logger.voice.warning(
                    "voice_turn_usage_post_failed turn=\(turnIdx, privacy: .public) error=\(error.localizedDescription, privacy: .private)",
                )
            }
        }

        // Notify VM so it can aggregate for the close-summary trace.
        let summary = LiveTurnSummary(
            turnIndex: pending.turnIndex,
            promptTokensText: turnUsage.promptTokensText,
            promptTokensAudio: turnUsage.promptTokensAudio,
            promptTokensTotal: turnUsage.promptTokensTotal,
            responseTokensText: turnUsage.responseTokensText,
            responseTokensAudio: turnUsage.responseTokensAudio,
            responseTokensTotal: turnUsage.responseTokensTotal,
            submittedAt: pending.submittedAt,
            latencyMs: pending.latencyMs,
            latencyTtfaMs: pending.latencyTtfaMs,
            containedToolCall: pending.containedToolCall,
            endedReason: turnUsage.endedReason,
            endedAt: pending.endedAt,
        )
        onTurnFinalized?(summary)

        // Surface the textual exchange to the UI layer for the voice-
        // active transcript card. Pulled from the `pending` snapshot
        // (captured pre-reset) — `currentTurnInlineText` and
        // `currentTurnUserTranscript` are already nil at this point
        // because the per-turn reset block above runs before
        // `flushPendingReport`. Either side may be empty (tool-call-
        // only turns produce no model text; very short utterances may
        // produce no user transcription frames) — consumers decide
        // whether to render.
        if let transcript = pending.transcript {
            onTurnTranscriptFinalized?(transcript)
        }
    }

    // MARK: - awaitTurnComplete

    /// Await the server's `turnComplete` frame. Mirrors `awaitSetupComplete`'s
    /// timeout pattern so a stalled server (no close, no `turnComplete`)
    /// can't hang the mic forever. Budget comes from `LiveSessionBudget`
    /// so it's tunable alongside the other Live-path budgets after D.1.
    /// On timeout, the caller's `endTurn` throws `.turnDrained`, the VM
    /// surfaces a toast, and state is recoverable by tapping again.
    func awaitTurnComplete(
        timeoutSec: Double = LiveSessionBudget.turnCompleteSec,
    ) async throws {
        turnCompleteGeneration += 1
        let gen = turnCompleteGeneration
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.turnCompleteContinuation = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSec))
                // Only fire if the continuation we OWN is still pending.
                // A newer turn would have bumped the generation; in that
                // case the old timeout silently no-ops so we don't poison
                // the live turn.
                guard let self,
                      self.turnCompleteGeneration == gen,
                      let pending = self.turnCompleteContinuation
                else { return }
                self.turnCompleteContinuation = nil
                pending.resume(throwing: RealtimeSessionError.turnDrained)
            }
        }
    }

    // MARK: - Inbound frame routing

    func handleInboundFrame(_ frame: LiveInboundFrame) async {
        // P1-I (2026-04-23): short-circuit on a torn-down session. If a
        // frame is mid-delivery when close() races in, the handler
        // could advance the state machine (.modelSpeaking, .ready, etc.)
        // on a session the VM has already disposed — producing Sentry
        // noise and, in tests, flakiness. The state machine's
        // `forceClose()` at close() sets state to .closed; once terminal,
        // no further advances should fire. Generation-token suppression
        // at the dispatcher level handles the common case, but a frame
        // already in the switch when cancel lands slips past it — this
        // guard closes that window.
        if stateMachine.state == .closed {
            return
        }
        switch frame {
        case .setupComplete:
            // Nil-clear BEFORE resume so a re-entrant resume (shouldn't
            // happen, but defense-in-depth against Google sending two
            // setupComplete frames) doesn't double-resume.
            if let cont = setupCompleteContinuation {
                setupCompleteContinuation = nil
                cont.resume()
            }

        case let .serverContent(content):
            await handleServerContent(content)

        case let .toolCall(toolCall):
            await handleToolCall(toolCall)

        case let .usageMetadata(usage):
            // Gemini Live streams usage as per-chunk deltas (prompt count
            // on first frame, response deltas on every audio chunk, empty
            // envelope on turnComplete). Accumulate rather than overwrite
            // so the empty turnComplete envelope doesn't zero out all the
            // real token counts — the bug that caused every $ai_generation
            // to report 0 tokens in prod 2026-04-22 before this fix.
            turnUsageAccumulator.accumulate(usage)
            #if DEBUG
            VoiceSessionLog.log("usage.metadata", [
                "frame_prompt_tokens": usage.promptTokenCount,
                "frame_response_tokens": usage.responseTokenCount,
                "frame_cached_tokens": usage.cachedContentTokenCount.map { "\($0)" } ?? "nil",
                "accum_prompt_tokens": turnUsageAccumulator.sumPromptTokens,
                "accum_response_tokens": turnUsageAccumulator.sumResponseTokens,
                "accum_cached_tokens": turnUsageAccumulator.sumCachedContentTokens,
                "has_pending_report": pendingReport != nil,
            ])
            #endif
            // Early-fire any turn report that was waiting on this
            // metadata. Common path when Gemini sends usageMetadata in
            // a trailing envelope AFTER `serverContent{turnComplete}`.
            if pendingReport != nil {
                flushPendingReport(dueTo: .usageArrived)
            }

        case let .goAway(ms):
            Logger.voice.info(
                "live_session_go_away time_before_disconnect_ms=\(ms ?? -1, privacy: .public)",
            )
            #if DEBUG
            VoiceSessionLog.log("server.go_away", ["time_before_disconnect_ms": ms ?? -1])
            #endif
            // Server-initiated refresh (goAway = server about to drop
            // this session within `ms`). Fire telemetry then run the
            // refresh handshake. `isRefreshing` guard inside
            // `refreshSession()` keeps a concurrent threshold-triggered
            // refresh from racing. ADR 0014.
            if !isRefreshing {
                await refreshSession(reason: "goaway")
            }

        case .sessionResumption:
            #if DEBUG
            VoiceSessionLog.log("server.session_resumption_update")
            #endif
        case let .unknown(key):
            #if DEBUG
            VoiceSessionLog.log("server.unknown_frame", ["key": key])
            #endif
        }
    }

    private func handleServerContent(_ content: LiveServerContent) async {
        if !content.audioChunks.isEmpty {
            // Record timestamp BEFORE state transitions / playback.
            // Mic-forwarder reads this for the echo cooldown gate.
            let now = Date()
            lastInboundAudioAt = now
            // TTFA capture: stamp "user finished speaking" the moment the
            // server's transcription flips `finished=true`. Only stamp
            // once per turn — partial-transcription frames with
            // `finished=false` shouldn't move the anchor backwards.
            if firstModelAudioAt == nil {
                firstModelAudioAt = now
            }
            #if DEBUG
            VoiceSessionLog.log("audio.chunk", [
                "count": content.audioChunks.count,
                "state": stateMachine.state.rawValue,
            ])
            #endif
            // Hands-free: audio chunks can arrive from ANY non-terminal
            // state because the mic is always hot and VAD drives turn
            // transitions server-side without iOS prior notice.
            //
            //   .userSpeaking  → .modelSpeaking  (user paused, server
            //                                     VAD fired, response
            //                                     arrived — no tap)
            //   .thinking      → .modelSpeaking  (original tap-to-end
            //                                     path — VM advanced
            //                                     to thinking before)
            //   .toolCalling   → .modelSpeaking  (CLAUDE.md #9 — model
            //                                     auto-continues after
            //                                     toolResponse)
            //   .ready         → .modelSpeaking  (next-turn response
            //                                     arrived while iOS
            //                                     was between turns)
            //
            // Already-.modelSpeaking is a no-op (the guard avoids a
            // redundant .modelSpeaking → .modelSpeaking transition
            // which canTransition disallows).
            switch stateMachine.state {
            case .userSpeaking, .thinking, .toolCalling, .ready:
                stateMachine.advance(to: .modelSpeaking)
            default:
                break
            }
            // Rearm the watchdog on every audio chunk. The onTransition
            // hook arms it on entry to .modelSpeaking, but subsequent
            // chunks in the same modelSpeaking window need the timer
            // reset so a turn that spans e.g. 15s of audio doesn't
            // self-trigger halfway through.
            rearmTurnStuckWatchdog()
            // Break on first failure — if `enqueuePlayback` throws,
            // the audio engine is stopped and every subsequent chunk
            // in this frame will fail the same way. One log per failed
            // turn is sufficient for triage; absent the break, a
            // failed turn would log ~50 warnings.
            for chunk in content.audioChunks {
                do {
                    try audioPipeline?.enqueuePlayback(chunk)
                } catch {
                    Logger.voice.warning(
                        "live_playback_enqueue_failed error=\(error.localizedDescription, privacy: .private)",
                    )
                    break
                }
            }
        }
        if let text = content.inlineText, !text.isEmpty {
            currentTurnInlineText = (currentTurnInlineText ?? "") + text
        }
        // Diagnostic + long-term transcript source. When
        // `inputAudioTranscription` is in the mint setup, the server
        // returns per-delta transcripts of what it heard from the
        // user. Zero-transcription output over several seconds of
        // apparent speech = audio pipeline problem, not a VAD problem.
        if let input = content.inputTranscription, !input.text.isEmpty {
            #if DEBUG
            VoiceSessionLog.log("transcription.user", [
                "text": input.text,
                "finished": input.finished,
            ])
            #endif
            // TTFA capture: stamp the user-end anchor on every
            // transcription frame that arrives BEFORE first model
            // audio. The latest pre-audio transcription frame is the
            // closest proxy to "server's VAD finalized the user's turn"
            // — once audio starts, later transcription frames are
            // irrelevant and must not move the anchor forward (that
            // would underestimate TTFA).
            //
            // Gemini Live with `automaticActivityDetection` doesn't
            // reliably emit `inputTranscription.finished=true` in
            // Stir's mint configuration (observed 2026-04-22:
            // cook_turn_resolved events showed ttfa_ms=0 across 30+
            // real-world turns because every transcription frame
            // arrived with `finished=false`, never tripping the prior
            // `if input.finished` guard). Stamping on every pre-audio
            // frame is the robust fallback — `finished=true` frames
            // still work identically since they're pre-audio in the
            // normal turn ordering.
            if firstModelAudioAt == nil {
                userTurnEndAt = Date()
            }
            // 2026-04-25: also accumulate into `currentTurnUserTranscript`
            // for the voice-active transcript card. Captured per-turn,
            // drained via `onTurnTranscriptFinalized` in `finalizeTurn`,
            // reset alongside `currentTurnInlineText`.
            //
            // ASSUMPTION: `input.text` is a delta, not a cumulative
            // transcription. The model-side accumulator (`currentTurnInlineText
            // += output.text`) ships in production with the same delta
            // assumption and works correctly, so by symmetry input.text
            // is also a delta. If device testing reveals stutter, flip
            // this to overwrite.
            currentTurnUserTranscript = (currentTurnUserTranscript ?? "") + input.text
        }
        if let output = content.outputTranscription, !output.text.isEmpty {
            // Accumulate model transcript into currentTurnInlineText
            // so VoiceTurn persistence gets a real string instead of
            // empty. Don't double-count inlineText (rare on AUDIO) +
            // outputTranscription on the same turn — prefer the
            // latter since it matches what was actually spoken.
            currentTurnInlineText = (currentTurnInlineText ?? "") + output.text
            #if DEBUG
            VoiceSessionLog.log("transcription.model", [
                "text": output.text,
                "finished": output.finished,
            ])
            #endif
        }
        if content.turnComplete {
            // Advance all the way to `.ready` so the hands-free loop
            // is self-sustaining — the next user utterance lands on a
            // legal `.ready → .modelSpeaking` edge without any VM
            // intervention.
            switch stateMachine.state {
            case .thinking, .toolCalling:
                stateMachine.advance(to: .modelSpeaking)
                stateMachine.advance(to: .ready)
            case .modelSpeaking, .userSpeaking:
                stateMachine.advance(to: .ready)
            default:
                break
            }
            // Finalize BEFORE resuming the continuation so `endTurn()`
            // reads a populated `lastTurnResult` when it wakes up.
            // finalizeTurn handles persistence, turnCount increment,
            // per-turn accumulator reset, and the refresh trigger.
            finalizeTurn()

            // The playback may still be queued — we resume the
            // continuation immediately so any waiting caller (VM
            // tap-to-end path) can react; audio continues playing in
            // the background. The VM calls cancelSpeaking / next tap
            // to interrupt if needed.
            //
            // Nil-clear before resume so a re-entrant turnComplete
            // (e.g., server emits one on audio end and another on
            // toolCall completion) doesn't double-resume.
            if let cont = turnCompleteContinuation {
                turnCompleteContinuation = nil
                cont.resume()
            }
        }
    }

    // MARK: - Transport-error recovery row

    /// Record the in-flight turn as a transport-error row and flush any
    /// pending usage report. Distinct from `finalizeTurn` which handles
    /// happy + watchdog paths — transport-error semantics are different:
    /// - No refresh trigger (we just tried and failed; the session is
    ///   dead or has already swapped to a new transport).
    /// - No new pendingReport creation (nothing downstream will drain it).
    /// - User turn is also marked `.error` (unlike watchdog, where user
    ///   DID speak successfully and only the model's response was
    ///   truncated — here both directions are compromised).
    ///
    /// Review finding P0-H / Critical #8 (2026-04-23). Prior behavior
    /// dropped the turn from both VoiceTurn history AND `ai_request_log`
    /// — ADR 0015's cap-reversal trigger query missed these entirely.
    func recordTurnAsTransportError() {
        guard turnStartedAt != nil else { return }
        let now = Date()
        let startedAt = turnStartedAt ?? now
        let totalMs = Int(now.timeIntervalSince(startedAt) * 1000)
        turnCount += 1

        let userIdx = voiceTurnRepository.nextTurnIndex(for: cookingSession)
        persistVoiceTurnPairSafely(
            user: .init(
                session: cookingSession,
                speaker: .user,
                turnIndex: userIdx,
                transcriptText: "",
                inputMode: .voice,
                latencyMs: 0,
                resultType: .error,
                errorCode: "transport_error",
            ),
            model: .init(
                session: cookingSession,
                speaker: .model,
                turnIndex: userIdx + 1,
                transcriptText: currentTurnInlineText ?? "",
                inputMode: .voice,
                latencyMs: totalMs,
                resultType: .error,
                errorCode: "transport_error",
            ),
            context: "transport_error_pair",
        )

        // Flush any in-flight pending usage report with the drain reason
        // that best fits: the session isn't really "closed" yet from the
        // VM's perspective, but for the voice-turn-usage POST's purposes
        // this is a terminal-for-this-turn signal. `.sessionClosed` is
        // the closest existing reason; a future enum addition could
        // introduce `.transportError` for dashboard clarity.
        if pendingReport != nil {
            flushPendingReport(dueTo: .sessionClosed)
        }

        // Reset per-turn state. No refresh trigger / pre-mint — session
        // is dead or was just swapped and the caller will either settle
        // back to .ready (on refresh success, handled in
        // handleTransportError's .success branch) or to .error.
        currentTurnInlineText = nil
        currentTurnUserTranscript = nil
        turnStartedAt = nil
        userTurnEndAt = nil
        firstModelAudioAt = nil
        turnContainedToolCall = false
        lastToolCallName = nil
    }
}
