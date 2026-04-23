// AudioInterruptionObserver
//
// Shared observer for the three AVAudioSession-adjacent events that can
// silently break an active voice session if unhandled:
//
//   - `interruptionNotification` .began  — phone call, Siri, timer alarm.
//     AVAudioEngine is force-stopped by the OS; mic tap ceases; any
//     long-lived WebSocket hangs on silence until idleDisconnect fires.
//   - `interruptionNotification` .ended + `.shouldResume` — interruption
//     cleared; the OS is hinting we may resume. Real recovery is
//     driver-specific (refresh the Live session, or re-prewarm
//     SpeechFallback); this observer just delivers the signal.
//   - `routeChangeNotification` reason=.oldDeviceUnavailable — AirPods
//     yank / BT disconnect. Mic + speaker just moved to handset; AEC
//     tuning is wrong for the new route; user usually hasn't noticed.
//   - `mediaServicesWereResetNotification` — the entire audio graph is
//     invalid. Must fully tear down + rebuild.
//
// P0-D (2026-04-23): created as part of review-orchestrator Critical #4
// remediation. Prior voice path had zero observers for any of these; a
// phone call mid-Cook-Mode wedged the session indefinitely. Both
// drivers (RealtimeSession + SpeechFallbackService) own an instance and
// react per path:
//
//   RealtimeSession:
//     .began              → cancel mic forwarder, stop playback, advance
//                           state to .error (VM falls back to C.3)
//     .ended(resume)      → attempt refreshSession; on failure advance
//                           to .error
//     .routeUnavailable   → same as .began (new route AEC is unreliable)
//     .mediaServicesReset → force-close; let VM rebuild from scratch
//
//   SpeechFallbackService:
//     .began              → cancel in-flight speech, advance state to
//                           .error (VM shows AI-VOICE-01 banner)
//     .ended(resume)      → state stays .error; next tap re-initializes
//     .routeUnavailable   → same as .began
//     .mediaServicesReset → same as .began
//
// The observer itself is path-agnostic — each driver implements its own
// recovery via the `handler` closure. Keep the observer thin; it only
// translates NotificationCenter userInfo dicts into typed events.

import AVFoundation
import Foundation

@MainActor
final class AudioInterruptionObserver {
    /// Typed event emitted to the owning driver. The driver decides what
    /// to do; this observer never touches AVAudioSession state itself.
    enum Event: Sendable, Equatable {
        /// OS began an interruption (phone call, Siri, timer alarm). The
        /// audio engine is paused externally and any mic tap has ceased
        /// firing.
        case interruptionBegan
        /// OS ended the interruption. `shouldResume=true` hints the OS
        /// expects the app to resume audio work; we treat it as a
        /// signal to attempt recovery but don't blindly trust it.
        case interruptionEnded(shouldResume: Bool)
        /// A previously-available audio route became unavailable mid-
        /// session (e.g., AirPods disconnected). The audio path just
        /// moved silently to a different device; AEC tuning and volume
        /// may be wrong for the new route. Treat as a hard interrupt.
        case routeOldDeviceUnavailable
        /// The system tore down the entire audio graph. AVAudioEngine,
        /// nodes, sessions — all invalid. Rebuild from scratch.
        case mediaServicesReset
    }

    private var observers: [NSObjectProtocol] = []
    private let handler: @MainActor (Event) -> Void

    init(handler: @escaping @MainActor (Event) -> Void) {
        self.handler = handler
    }

    /// Begin observing. Idempotent — calling twice without `stop()` is a
    /// bug but won't duplicate deliveries (we guard via observer list).
    func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default

        let interruption = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main,
        ) { [weak self] note in
            guard let self else { return }
            guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }
            switch type {
            case .began:
                Task { @MainActor [weak self] in
                    self?.handler(.interruptionBegan)
                }
            case .ended:
                let optsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
                let resume = options.contains(.shouldResume)
                Task { @MainActor [weak self] in
                    self?.handler(.interruptionEnded(shouldResume: resume))
                }
            @unknown default:
                break
            }
        }
        observers.append(interruption)

        let routeChange = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main,
        ) { [weak self] note in
            guard let self else { return }
            guard let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
            else { return }
            // Only the "old device unavailable" reason indicates a silent
            // route-change the user didn't trigger. Other reasons
            // (newDeviceAvailable, categoryChange, override,
            // wakeFromSleep, noSuitableRouteForCategory, routeConfigurationChange,
            // unknown) are either user-initiated or benign.
            if reason == .oldDeviceUnavailable {
                Task { @MainActor [weak self] in
                    self?.handler(.routeOldDeviceUnavailable)
                }
            }
        }
        observers.append(routeChange)

        let mediaReset = nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.handler(.mediaServicesReset)
            }
        }
        observers.append(mediaReset)
    }

    /// Stop observing. Idempotent.
    func stop() {
        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
        }
        observers.removeAll()
    }
}
