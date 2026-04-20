// AVAudioSessionConfigurator
//
// Shared `AVAudioSession` setup for Cook Mode voice. Reused by:
//   - SpeechFallbackService (C.3) — SFSpeechRecognizer + AVSpeechSynthesizer
//   - RealtimeSession (C.2, deferred) — AVAudioEngine PCM16 capture +
//     AVAudioPlayerNode playback for Gemini Live
//
// Category + mode choice (ADR 0007 pre-commits):
//   - `.playAndRecord` — both mic in and speaker out in one session
//   - `.voiceChat` mode — enables echo cancellation, tightens output
//     gain for voice (gets louder with less distortion)
//   - `.duckOthers` — kitchen apps like music ducking during a turn
//   - `.defaultToSpeaker` — without this, iPhone routes to earpiece
//     on phones that lack a proximity sensor signal
//   - `.allowBluetooth` — AirPods + kitchen BT speakers both work
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
    static func activateForCookMode() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetooth],
        )
        try session.setActive(true, options: [])
        isActiveForCookMode = true
        Logger.voice.info(
            "av_session_activated category=playAndRecord mode=voiceChat sampleRate=\(session.sampleRate, privacy: .public)",
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
