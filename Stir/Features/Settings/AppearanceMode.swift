// AppearanceMode
//
// User-selectable color scheme override for the app shell. Backs the
// Appearance card in `SettingsRootView` and is applied at the root via
// `.preferredColorScheme(_:)` on `RootView` so every surface (tabs,
// modals, navigation chrome) respects the choice.
//
// Default `.system` defers to iOS's user-level light/dark setting,
// which is the iOS-norm and what most users expect on first launch.
// `.light` / `.dark` are explicit user overrides. The selection is
// persisted via `@AppStorage` — same precedent as
// `ScanFlashMode` at `Stir/Features/Scan/ScanFlashMode.swift`.
//
// String raw values are deliberately chosen so a future
// `appearance_changed` telemetry event (if/when added to spec §15)
// would carry stable, low-cardinality strings. Renaming a case or
// rawValue is a wire-contract change.

import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// User-facing label for the segmented selector.
    var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// Value passed to `.preferredColorScheme(_:)`. `nil` means "defer
    /// to the iOS user-level setting" — SwiftUI treats a `nil` color
    /// scheme as no override.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

extension AppearanceMode {
    /// Shared `@AppStorage` key. Hoisted to a constant so the picker
    /// (Settings) and the consumer (RootView) can't drift.
    static let storageKey = "com.scalinity.stir.appearance.mode"
}
