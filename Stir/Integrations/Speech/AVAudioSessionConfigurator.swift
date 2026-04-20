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
        Logger.voice.info(
            "av_session_activated category=playAndRecord mode=voiceChat sampleRate=\(session.sampleRate, privacy: .public)",
        )
    }

    /// Deactivate on Cook Mode exit. `.notifyOthersOnDeactivation` wakes
    /// up any app we were ducking so music resumes immediately.
    static func deactivate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            Logger.voice.info("av_session_deactivated")
        } catch {
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
