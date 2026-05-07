// ScanFlashMode
//
// SCA-47 — user-selectable flash policy for the kitchen scan camera.
// Backs the toggle in ScanCaptureView's bottom chrome and is plumbed
// through CameraService.capturePhoto(flashMode:).
//
// Default `.off` preserves the SCA-39 instant-shutter invariant
// (flash off + photoQualityPrioritization=.speed brings shutter
// latency under ~150 ms). `.on` and `.auto` are user-opt-in for dark
// pantries — both pay the metering pre-flash latency penalty
// documented in SCA-39's commit message.
//
// Cycle order is `off → on → auto → off` (NOT Apple Camera's
// `auto → on → off → auto`) — Stir's home position is .off because
// SCA-39 made that choice for the latency floor; each tap should
// escalate from there toward more flash.
//
// String raw values are the wire-contract for `scan_started.flash_mode`
// telemetry (CLAUDE.md telemetry section + Spec §15). Renaming a case
// or rawValue is a wire-contract change — update both docs in lockstep.

import AVFoundation
import Foundation

enum ScanFlashMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case on
    case auto

    var id: String { rawValue }

    /// AVFoundation flash mode passed into `AVCapturePhotoSettings.flashMode`.
    /// 1:1 mapping — the user-facing enum exists so we can persist a
    /// stable telemetry string and keep `AVCaptureDevice.FlashMode`
    /// (which is an Int-backed @objc enum) out of `@AppStorage`.
    var avFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off:  return .off
        case .on:   return .on
        case .auto: return .auto
        }
    }

    /// SF Symbol name for the toggle button. `bolt.slash.fill` reads
    /// as "no flash"; `bolt.fill` reads as "flash on"; the Apple-
    /// supplied `bolt.badge.automatic.fill` includes a glyphic "A"
    /// badge so the auto state is unambiguous against `.on`.
    var sfSymbol: String {
        switch self {
        case .off:  return "bolt.slash.fill"
        case .on:   return "bolt.fill"
        case .auto: return "bolt.badge.automatic.fill"
        }
    }

    /// VoiceOver label. Surfaces the current state plus the next
    /// state so users navigating with VoiceOver understand what a
    /// tap will do without needing to discover the cycle by trial.
    var accessibilityLabel: String {
        switch self {
        case .off:  return "Flash off. Tap to turn flash on."
        case .on:   return "Flash on. Tap to set flash to automatic."
        case .auto: return "Flash automatic. Tap to turn flash off."
        }
    }

    /// Advance one position in the cycle. Pure — caller stores the
    /// result back into `@AppStorage` themselves.
    func next() -> ScanFlashMode {
        switch self {
        case .off:  return .on
        case .on:   return .auto
        case .auto: return .off
        }
    }
}
