// RealtimeSessionAudioIO
//
// SCA-79 — extracted from RealtimeSession.swift. Owns:
//
//   - **Outbound mic forwarding**: PCM16 → base64 →
//     `input_audio_buffer.append` frames pushed onto the live transport,
//     with the half-duplex mute window during model speech / playback
//     drain / refresh handoff.
//   - **AVAudioSession event handling**: interruption, route change,
//     media-services-reset routing into a clean teardown.
//   - **Foreground mic-permission re-check**: detects mid-session
//     revocation in Settings and force-closes.
//
// SCA-168 S6 (CR2): bucket *ownership* matters for ad-hoc reasoning
// about who-touches-what — clarifying:
//
//   Owns (read + write):
//     - `audioPipeline`           (instantiated by the main file's
//                                  preWarm; this bucket calls into it)
//     - `micForwardTask`          (created/cancelled here; also
//                                  cancelled by main close + StateMachine
//                                  refresh post-commit failure)
//     - `audioInterruptionObserver`, `foregroundObserver`
//                                 (start here; stop in main close)
//
//   Consumes (read-only from this file):
//     - `transport`               (read on every mic-frame iteration to
//                                  pick up a refresh-time swap dynamically)
//     - `stateMachine.state`      (mute-gate condition)
//     - `isRefreshing`            (mute-gate condition during the
//                                  ~1.7-3.6s refresh handoff)
//     - per-turn anchors (`turnStartedAt` etc.) — only read from
//       `handleAudioInterruption` to decide if a turn must be recorded
//       as transport-error before tearing down.
//
// All instance stored properties live on the main `RealtimeSession`
// class declaration (Swift extensions in separate files cannot host
// stored properties). Methods here read them via `self`.
//
// SCA-168 S10 (CR3): `Logger.voice` is declared in
// `Speech/AVAudioSessionConfigurator.swift`. A future relocation of
// the Speech bucket must keep the `static let voice` declaration
// reachable from this file; same applies to the other three GeminiLive
// files that use the logger.

import AVFoundation
import Foundation
import OSLog
import UIKit

extension RealtimeSession {

    // MARK: - Audio interruption + permission

    /// Register the AudioInterruptionObserver so AVAudioSession
    /// interruption / route-change / media-services-reset events are
    /// routed to `handleAudioInterruption(_:)`. Idempotent — if an
    /// observer already exists (shouldn't happen given preWarm semantics,
    /// but defensive), we stop the prior one first.
    func startAudioInterruptionObserver() {
        audioInterruptionObserver?.stop()
        audioInterruptionObserver = AudioInterruptionObserver { [weak self] event in
            self?.handleAudioInterruption(event)
        }
        audioInterruptionObserver?.start()

        // P0-F (2026-04-23): foreground-mic-permission re-check. Users
        // can revoke mic access in Settings while Cook Mode is
        // backgrounded; on return the AVAudioEngine continues reporting
        // zero-peak buffers forever with no error. On foreground,
        // re-query `AVAudioApplication.shared.recordPermission` and
        // force-close if denied.
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main,
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.checkMicPermissionOnForeground()
                }
            }
        }
    }

    private func checkMicPermissionOnForeground() {
        let status = AVAudioApplication.shared.recordPermission
        guard status == .denied else { return }
        Logger.voice.warning(
            "voice_live_mic_permission_revoked — closing session on foreground; user must re-grant in Settings",
        )
        #if DEBUG
        VoiceSessionLog.log("mic_permission_revoked_on_foreground")
        #endif
        // Treat as interruption-class event: tear down + surface .error
        // so VM routes to C.3 (which will itself check permission and
        // also hard-fail, but that's the existing VM path).
        handleAudioInterruption(.mediaServicesReset)
    }

    /// React to system audio events. Scope is deliberately narrow: we
    /// tear down the Live path cleanly and let the VM's existing
    /// fallback-to-C.3 flow (via `.error` state) handle the user-facing
    /// recovery. Attempting an in-place refresh on `.interruptionEnded`
    /// is risky — the OS may be mid-interruption on the AVAudioSession
    /// even after announcing end, and forcing Realtime audio through
    /// a half-valid session produces worse UX than a clean "tap again
    /// to re-start voice" cue.
    private func handleAudioInterruption(_ event: AudioInterruptionObserver.Event) {
        Logger.voice.info(
            "voice_live_audio_interruption event=\(String(describing: event), privacy: .public)",
        )
        #if DEBUG
        VoiceSessionLog.log("audio_interruption", [
            "event": String(describing: event),
            "state": stateMachine.state.rawValue,
        ])
        #endif
        switch event {
        case .interruptionBegan, .routeOldDeviceUnavailable, .mediaServicesReset:
            // Treat all three as "the session is unrecoverable, tear
            // down and let VM fall back." Mid-turn VoiceTurn persist
            // runs via `recordTurnAsTransportError` so ai_request_log
            // + the session's $ai_trace get the aborted-turn row for
            // ADR 0015 cap-reversal trigger visibility.
            if turnStartedAt != nil {
                recordTurnAsTransportError()
            }
            // Cancel in-flight playback so the speaker goes quiet
            // immediately — the interruption handler (OS-level audio
            // pause) has already muted our output but our local
            // pendingPlaybackBuffers may still be scheduling sound
            // that'd surge back when the interruption clears.
            audioPipeline?.cancelPlayback()
            if stateMachine.state != .closed && stateMachine.state != .error {
                stateMachine.advance(to: .error)
            }
        case .interruptionEnded(let shouldResume):
            // Log + leave session in its current state. The user's next
            // tap triggers a fresh preWarm via the VM rebuild path,
            // which gets a clean session + re-activated audio session.
            // Auto-resuming in-place adds risk without clear UX value.
            Logger.voice.info(
                "voice_live_interruption_ended shouldResume=\(shouldResume, privacy: .public) — session stays in error; next tap rebuilds",
            )
        }
    }

    // MARK: - Mic forwarding

    func startMicForwarding() {
        guard let pipeline = audioPipeline else { return }
        // P1-F (2026-04-23): guard against stacking forwarders. Without
        // this, a defensive re-invoke (e.g. belt-and-suspenders
        // `beginTurn` call after error recovery) would assign a new
        // Task to `micForwardTask` while the prior one still holds
        // the `for await pipeline.micFrames` single-consumer iterator.
        // The new Task sees `.finished` immediately and exits; the OLD
        // one keeps forwarding but is no longer referenced — leaked
        // until `close()`. Silent bug class; match the refresh step-10
        // pattern (line 1265: `if micForwardTask == nil`).
        guard micForwardTask == nil else {
            #if DEBUG
            VoiceSessionLog.log("mic_forwarder.start_skipped_already_running")
            #endif
            return
        }
        // Self-capture (weak) so the Task reads `self.transport` on
        // every iteration. `pipeline.micFrames` is a single-consumer
        // AsyncStream created once in LiveAudioPipeline.init; starting
        // a second iteration after cancellation returns immediately
        // with `.finished`. So the forwarder must stay ALIVE across
        // refreshes and pick up the swapped transport dynamically —
        // cancelling + restarting was the bug that stopped mic sends
        // after turn 10's refresh (observed 2026-04-22: mic_tap_fired
        // continued firing but zero mic.sent entries post-refresh).
        micForwardTask = Task { [weak self] in
            guard let self else { return }
            #if DEBUG
            var framesSent = 0
            var bytesSent = 0
            var framesMuted: UInt64 = 0
            var nextLogAtFrame = 50 // ~1 s at 20 ms per frame
            #endif
            // Track the playerNode's running state so we can detect
            // the instant playback transitions from playing→stopped.
            // The cooldown window is measured from THAT transition,
            // not from the server's last audio chunk, because the
            // local AVAudioPlayerNode continues draining buffered
            // audio for 1-2s after the server stops sending chunks.
            // Without this, the cooldown expired while the speaker
            // was still emitting audio and the mic captured the tail
            // (observed 2026-04-22: "heat until", "step", "stick",
            // "then", "kiri" — model transcribing its own playback).
            var wasPlayingBack = false
            var lastPlaybackEndedAt: Date?
            for await frame in pipeline.micFrames {
                if Task.isCancelled { break }
                // Dynamically fetch the CURRENT transport. Nil during
                // the brief window between old-close and new-ready in
                // a refresh; we drop those frames (acceptable — the
                // user is typically silent at turn boundaries).
                guard let transport = self.transport else { continue }
                // Three-part half-duplex gate:
                //
                //   A. state == .modelSpeaking — server reports it's
                //      mid-utterance. Explicit, fast.
                //   B. pipeline.isPlayingBack — local player has
                //      scheduled buffers still draining. Covers the
                //      gap between last server chunk and speaker
                //      silence.
                //   C. now - lastPlaybackEndedAt < echoCooldownSec —
                //      AEC adapt window + room reverb tail after the
                //      speaker actually stopped.
                //
                // AEC (via AVAudioSession mode = .voiceChat) attenuates
                // the echo signal, but server-side VAD can still fire
                // on a -30dB residual given enough time. This gate is
                // the hard backstop.
                //
                // Cost: user can't barge in while model is speaking.
                // Acceptable for MVP — can be re-enabled later if AEC
                // quality proves sufficient in D.1 validation.
                let isPlayingNow = pipeline.isPlayingBack
                if wasPlayingBack && !isPlayingNow {
                    lastPlaybackEndedAt = self.now()
                }
                wasPlayingBack = isPlayingNow

                let inModelSpeaking = self.stateMachine.state == .modelSpeaking
                let inPostPlaybackCooldown: Bool = {
                    guard let ended = lastPlaybackEndedAt else { return false }
                    return self.now().timeIntervalSince(ended) < LiveSessionBudget.echoCooldownSec
                }()
                // Fourth mute path: active session refresh. During the
                // ~1.7-3.6s handoff we must NOT forward mic audio across
                // the transport swap — if we do, frames land on the new
                // session mid-stream without a clean silence-to-speech
                // VAD boundary, and semantic VAD never fires end-of-speech
                // on the first utterance. Symptom: user speaks after
                // refresh, nothing happens; says it again and it works.
                // Observed 2026-04-22 PM: 43s of mic.sent events post-
                // refresh with zero transcription.user / serverContent,
                // then a second utterance transcribed normally.
                // Dropping frames during refresh means the user's words
                // spoken mid-handoff are lost — but that's a tiny window
                // (~2s at best, ~4s at worst) at a turn boundary where
                // the user is typically silent anyway, and it's vastly
                // preferable to the current 43s dead zone.
                let inRefresh = self.isRefreshing
                let muted = inModelSpeaking || isPlayingNow || inPostPlaybackCooldown || inRefresh
                if muted {
                    #if DEBUG
                    framesMuted &+= 1
                    if framesMuted % 50 == 1 {
                        VoiceSessionLog.log("mic.muted_half_duplex", [
                            "frames_muted": framesMuted,
                            "state": self.stateMachine.state.rawValue,
                            "playing": isPlayingNow,
                            "cooldown": inPostPlaybackCooldown,
                            "refresh": inRefresh,
                        ])
                    }
                    #endif
                    continue
                }
                guard pipeline.captureGate.accepts(frame.captureEpoch) else { continue }
                do {
                    try await transport.send(.realtimeInputAudio(
                        base64: frame.base64,
                        mimeType: frame.mimeType,
                    ))
                    self.micFramesSentTotal += 1
                    #if DEBUG
                    framesSent += 1
                    bytesSent += frame.base64.count
                    // Log every ~1 s of audio so we can see in the
                    // console whether the mic pipeline is actually
                    // pushing bytes. If this log never appears while
                    // user is obviously speaking, the AVAudioEngine
                    // tap callback isn't firing and the whole
                    // "silence from the model" problem is on iOS side.
                    if framesSent >= nextLogAtFrame {
                        VoiceSessionLog.log("mic.sent", [
                            "frames": framesSent,
                            "b64_bytes": bytesSent,
                        ])
                        nextLogAtFrame = framesSent + 50
                    }
                    #endif
                } catch {
                    // Don't `break` — a send failure is typically a
                    // refresh-swap teardown of the OLD transport. The
                    // next iteration reads `self.transport` fresh and
                    // picks up the new one. Breaking killed the forwarder
                    // forever post-refresh (observed 2026-04-22, turn 10
                    // onward: zero `mic.sent` events after handoff).
                    Logger.voice.warning(
                        "live_mic_send_failed error=\(error.localizedDescription, privacy: .private)",
                    )
                    #if DEBUG
                    VoiceSessionLog.logError("mic.send_failed", error: error)
                    #endif
                    continue
                }
            }
        }
    }

    // MARK: - Audio health

    /// Engine reported a hardware configuration change. iOS has already
    /// stopped it, so the mic and speaker are both dead until restarted.
    func handleEngineConfigurationChange() {
        guard let pipeline = audioPipeline else { return }
        // Our own restart can trigger a further notification after the
        // engine is back up; a running engine needs nothing here (the
        // health check still catches a tap that came back dead).
        guard !pipeline.isEngineRunning else { return }
        if pipeline.isCapturing {
            recoverAudioEngine(reason: "engine_configuration_change")
        } else {
            // Before the first turn: nothing is listening yet. Drop any
            // playback the stopped engine stranded; the next
            // `startCapture` or `enqueuePlayback` starts the engine again.
            pipeline.cancelPlayback()
        }
    }

    func startAudioHealthMonitor() {
        guard audioHealthTask == nil else { return }
        audioHealthTask = Task { @MainActor [weak self] in
            let nanos = UInt64(LiveSessionBudget.audioHealthCheckIntervalSec * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled, let self else { return }
                self.checkAudioHealth()
            }
        }
    }

    /// One health pass. Two failure shapes, both silent before this
    /// existed:
    ///   1. Playback buffers that will never report done, which keep the
    ///      half-duplex gate shut so no mic audio is sent.
    ///   2. A mic tap that stopped firing (engine stopped, or the tap
    ///      was installed against a format the engine no longer uses).
    func checkAudioHealth() {
        let state = stateMachine.state
        guard state != .closed, state != .error, !isRefreshing,
              let pipeline = audioPipeline
        else { return }

        if pipeline.playbackOverdue(grace: LiveSessionBudget.playbackOverdueGraceSec) {
            Logger.voice.warning(
                "live_playback_callbacks_lost pending=\(pipeline.pendingPlaybackBufferCount, privacy: .public) state=\(state.rawValue, privacy: .public) — resetting playback so the mic can reopen",
            )
            SentryReporter.shared.breadcrumb(
                category: "voice",
                message: "playback callbacks lost, reset",
                data: ["pending": String(pipeline.pendingPlaybackBufferCount), "state": state.rawValue],
            )
            pipeline.cancelPlayback()
        }

        guard pipeline.isCapturing else { return }
        if !pipeline.isEngineRunning {
            recoverAudioEngine(reason: "engine_stopped")
        } else if pipeline.secondsSinceLastMicTap() > LiveSessionBudget.micTapStallSec {
            recoverAudioEngine(reason: "mic_tap_stalled")
        }
    }

    /// Restart the audio path in place. Bounded: past
    /// `maxAudioRecoveriesPerWindow` restarts in `audioRecoveryWindowSec`,
    /// or if the engine will not start, the session moves to `.error` so
    /// Cook Mode drops back to "Ask with voice" and the next tap builds a
    /// fresh session. Either outcome is reported to Sentry, because until
    /// now this failure left no trace at all.
    func recoverAudioEngine(reason: String) {
        let state = stateMachine.state
        guard state != .closed, state != .error, let pipeline = audioPipeline else { return }
        let nowDate = now()
        audioRecoveryTimes.removeAll {
            nowDate.timeIntervalSince($0) >= LiveSessionBudget.audioRecoveryWindowSec
        }
        let context: [String: String] = [
            "reason": reason,
            "state": state.rawValue,
            "mic_frames_sent": String(micFramesSentTotal),
            "recoveries_in_window": String(audioRecoveryTimes.count),
        ]
        guard audioRecoveryTimes.count < LiveSessionBudget.maxAudioRecoveriesPerWindow else {
            failAudioSession(reason: reason, context: context)
            return
        }
        audioRecoveryTimes.append(nowDate)
        do {
            try pipeline.restartCapture()
            Logger.voice.warning(
                "live_audio_recovered reason=\(reason, privacy: .public) state=\(state.rawValue, privacy: .public)",
            )
            #if DEBUG
            VoiceSessionLog.log("audio.recovered", ["reason": reason, "state": state.rawValue])
            #endif
            SentryReporter.shared.captureError(
                VoiceAudioStallError(reason: reason, recovered: true),
                context: context,
            )
        } catch {
            Logger.voice.error(
                "live_audio_restart_failed reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .private)",
            )
            failAudioSession(reason: reason, context: context)
        }
    }

    private func failAudioSession(reason: String, context: [String: String]) {
        Logger.voice.error(
            "live_audio_unrecoverable reason=\(reason, privacy: .public) — ending voice session",
        )
        #if DEBUG
        VoiceSessionLog.log("audio.unrecoverable", ["reason": reason])
        #endif
        SentryReporter.shared.captureError(
            VoiceAudioStallError(reason: reason, recovered: false),
            context: context,
        )
        if turnStartedAt != nil {
            recordTurnAsTransportError()
        }
        audioPipeline?.cancelPlayback()
        if stateMachine.state != .closed && stateMachine.state != .error {
            stateMachine.advance(to: .error)
        }
    }
}

/// Reported to Sentry when the Live audio path stalls. `recovered` says
/// whether an in-place restart brought it back or the session had to end.
struct VoiceAudioStallError: Error, LocalizedError, Equatable, Sendable {
    let reason: String
    let recovered: Bool

    var errorDescription: String? {
        "Voice audio stalled (\(reason)); \(recovered ? "restarted" : "session ended")"
    }
}
