// RealtimeSessionAudioIO
//
// SCA-79 — extracted from RealtimeSession.swift. Owns the outbound mic
// path (PCM16 → base64 → realtimeInput.audio frames), the half-duplex
// mute window during model speech / playback drain / refresh handoff,
// AVAudioSession interruption + route-change + media-services-reset
// handling, and the foreground mic-permission re-check.
//
// All instance stored properties (audioPipeline, audioInterruptionObserver,
// foregroundObserver, micForwardTask, lastInboundAudioAt, transport,
// stateMachine, etc.) live on the main RealtimeSession class declaration
// in RealtimeSession.swift. Methods here read them via `self`.

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
    /// even after announcing end, and forcing Gemini Live audio through
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
                    lastPlaybackEndedAt = Date()
                }
                wasPlayingBack = isPlayingNow

                let inModelSpeaking = self.stateMachine.state == .modelSpeaking
                let inPostPlaybackCooldown: Bool = {
                    guard let ended = lastPlaybackEndedAt else { return false }
                    return Date().timeIntervalSince(ended) < LiveSessionBudget.echoCooldownSec
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
                    // P3-C (2026-04-23): brief sleep instead of tight
                    // read-and-drop during mute. Without the sleep, the
                    // forwarder wakes on every 20 ms mic frame (50 Hz)
                    // and burns MainActor contention while the user
                    // hears 5-15 s of model speech. With the sleep we
                    // release the MainActor for SwiftUI/other work and
                    // re-check gate conditions on the next tick. 100 ms
                    // is a balance: short enough that post-mute mic
                    // resumption doesn't perceptibly lag (user has to
                    // react to model finishing speaking anyway — their
                    // utterance starts well after the 100 ms window),
                    // long enough to materially reduce wake-ups during
                    // a ~10 s model turn (~100 wakes vs ~500 without).
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                do {
                    try await transport.send(.realtimeInputAudio(
                        base64: frame.base64,
                        mimeType: frame.mimeType,
                    ))
                    #if DEBUG
                    framesSent += 1
                    bytesSent += frame.base64.count
                    // Log every ~1 s of audio so we can see in the
                    // console whether the mic pipeline is actually
                    // pushing bytes. If this log never appears while
                    // user is obviously speaking, the AVAudioEngine
                    // tap callback isn't firing and the whole
                    // "silence from Gemini" problem is on iOS side.
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

    private func stopMicForwarding() {
        micForwardTask?.cancel()
        micForwardTask = nil
    }
}
