// AVAudioSessionConfigurator
//
// Shared `AVAudioSession` setup for Cook Mode voice. Reused by:
//   - SpeechFallbackService (C.3) — SFSpeechRecognizer + AVSpeechSynthesizer
//   - RealtimeSession (C.2, deferred) — AVAudioEngine PCM16 capture +
//     AVAudioPlayerNode playback for Gemini Live
//
// Category + mode choice (ADR 0007 pre-commits):
//   - `.playAndRecord` — both mic in and speaker out in one session
//   - `.videoChat` mode — enables echo cancellation (same Voice
//     Processing IO unit as `.voiceChat`) but routes to the speaker
//     by default and uses a flatter frequency response suited to
//     dual-direction voice rather than telephony. `.voiceChat`
//     produced earpiece-like output on iPhone even with
//     `.defaultToSpeaker` + `overrideOutputAudioPort(.speaker)` set
//     (observed 2026-04-23: "coming out as if you were on a
//     phonecall"). `.videoChat` is what FaceTime/Meet-class apps
//     use for the same reason.
//   - `.duckOthers` — kitchen apps like music ducking during a turn
//   - `.defaultToSpeaker` — redundant under `.videoChat` (mode sets
//     it implicitly per Apple docs), but kept as explicit belt +
//     suspenders. If Apple ever changes `.videoChat` to not imply
//     speaker routing, this keeps the current behavior stable.
//   - `.allowBluetoothHFP` — AirPods + kitchen BT speakers both work
//     (renamed from deprecated `.allowBluetooth` in iOS 8; same
//     hands-free-profile semantic, no behavior change)
//
// Activate/deactivate is idempotent at Cook Mode entry; safe to call
// multiple times. Deactivate with `.notifyOthersOnDeactivation` so
// ducked audio apps resume cleanly.

import AVFoundation
import Foundation
import OSLog

@MainActor
enum AVAudioSessionConfigurator {

    /// Tracks our own view of the session's active state so we don't
    /// call `setActive(false)` on an already-inactive session and log
    /// a spurious warning every time. Normal Cook Mode exit calls
    /// `deactivate()` from VM.exit() first, then `.onDisappear` calls
    /// it again as defense-in-depth — without this flag, the second
    /// call logs `av_session_deactivate_failed` every time.
    private static var isActiveForCookMode = false

    /// Configure the shared `AVAudioSession` for Cook Mode voice. Call once
    /// on Cook Mode entry (before pre-warming STT/TTS). Safe to re-call;
    /// `setCategory` is a no-op when values are unchanged.
    ///
    /// Blocks the calling thread for as long as the OS takes to activate
    /// the session. Prefer `activateForCookModeOffMain()` from async code.
    static func activateForCookMode() throws {
        try configureSessionForCookMode()
        isActiveForCookMode = true
    }

    /// Same configuration as `activateForCookMode()`, but the blocking
    /// `setCategory` / `setActive(true)` / speaker-override calls run on a
    /// background thread and the main actor only awaits the result.
    ///
    /// Apple documents session activation as a synchronous, potentially
    /// slow call and recommends keeping it off the main thread. With the
    /// `.videoChat` mode (Voice Processing IO) it can take seconds,
    /// especially on the simulator, and doing it on the main actor at Cook
    /// Mode entry lined up with a fully-blocked App Hang in Sentry
    /// (STIR-H, Nov 6 2026: sheet presented, then a 3.6-4.4 s freeze).
    /// AVAudioSession is thread-safe, so only the hop changes; the calls,
    /// their order and their options are identical.
    static func activateForCookModeOffMain() async throws {
        try await Task.detached(priority: .userInitiated) {
            try AVAudioSessionConfigurator.configureSessionForCookMode()
        }.value
        isActiveForCookMode = true
    }

    /// The actual session configuration. `nonisolated` so it can run on a
    /// background thread; touches no main-actor state.
    nonisolated private static func configureSessionForCookMode() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .videoChat,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP],
        )
        try session.setActive(true, options: [])
        // Force speaker routing explicitly. `.defaultToSpeaker` is a
        // category option hint, but `.voiceChat` mode can still route
        // to the earpiece on some iPhone models with proximity sensing
        // (observed 2026-04-23: user reports quiet output while phone
        // is on a countertop, which is the earpiece-routing signature).
        // `overrideOutputAudioPort(.speaker)` is the authoritative override.
        do {
            try session.overrideOutputAudioPort(.speaker)
        } catch {
            // Non-fatal — the category-level `.defaultToSpeaker` still
            // applies, and some Bluetooth-connected routes refuse this
            // override. Log and continue.
            Logger.voice.warning(
                "av_session_speaker_override_failed: \(error.localizedDescription, privacy: .public)",
            )
        }
        Logger.voice.info(
            "av_session_activated category=playAndRecord mode=videoChat sampleRate=\(session.sampleRate, privacy: .public) speaker_override=ok",
        )
    }

    /// Deactivate on Cook Mode exit. `.notifyOthersOnDeactivation` wakes
    /// up any app we were ducking so music resumes immediately.
    ///
    /// Idempotent — second call while already inactive is a no-op, so
    /// normal-exit flow (VM.exit → CookModeRoot.onDisappear) doesn't
    /// log spurious failures.
    static func deactivate() {
        guard isActiveForCookMode else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            isActiveForCookMode = false
            Logger.voice.info("av_session_deactivated")
        } catch {
            // Leave `isActiveForCookMode = true` on failure so a retry
            // has a chance — the OS may have temporarily refused
            // (e.g., during an interruption).
            Logger.voice.warning(
                "av_session_deactivate_failed: \(error.localizedDescription, privacy: .public)",
            )
        }
    }
}

extension Logger {
    /// Subsystem logger for Cook Mode voice pipeline. Shared between C.3
    /// (Speech fallback) and C.2 (Gemini Live) so one filter catches both.
    static let voice = Logger(subsystem: "com.scalinity.stir", category: "Voice")
}
