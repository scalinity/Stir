// AppearanceModeTests
//
// Pins the pure-function surface of `AppearanceMode` — the user-
// selectable color-scheme override backing the Settings → Appearance
// card. Modeled after `ScanFlashModeTests`: persisted enums with
// stable rawValues need round-trip + mapping coverage so a future
// rename of a case or rawValue is caught at test-time (a silent
// rename would mean every user's stored preference resets to .system
// on the next launch).

import SwiftUI
import XCTest
@testable import Stir

final class AppearanceModeTests: XCTestCase {
    // MARK: - ColorScheme mapping

    /// `.system` is encoded as `nil` so SwiftUI's
    /// `.preferredColorScheme(nil)` defers to the iOS user-level
    /// setting (the documented "no override" behavior).
    func test_colorScheme_systemMapsToNil() {
        XCTAssertNil(AppearanceMode.system.colorScheme)
    }

    func test_colorScheme_lightMapsToLight() {
        XCTAssertEqual(AppearanceMode.light.colorScheme, .light)
    }

    func test_colorScheme_darkMapsToDark() {
        XCTAssertEqual(AppearanceMode.dark.colorScheme, .dark)
    }

    // MARK: - Telemetry / storage contract

    /// Raw values are the persisted-storage contract — `@AppStorage`
    /// writes these literals to UserDefaults. Renaming a case is a
    /// wire-contract change: existing users' stored preferences would
    /// silently fail to decode and reset to .system.
    func test_rawValue_matchesStorageContract() {
        XCTAssertEqual(AppearanceMode.system.rawValue, "system")
        XCTAssertEqual(AppearanceMode.light.rawValue, "light")
        XCTAssertEqual(AppearanceMode.dark.rawValue, "dark")
    }

    /// UserDefaults round-trip — a stored "dark" must decode back to
    /// .dark, and unknown / case-mismatched strings must fail rather
    /// than silently coerce.
    func test_initFromRawValue_roundTrips() {
        XCTAssertEqual(AppearanceMode(rawValue: "system"), .system)
        XCTAssertEqual(AppearanceMode(rawValue: "light"), .light)
        XCTAssertEqual(AppearanceMode(rawValue: "dark"), .dark)
        XCTAssertNil(AppearanceMode(rawValue: "Dark"), "case-sensitive — capitalized must not match")
        XCTAssertNil(AppearanceMode(rawValue: "auto"), "unknown raw values must not silently coerce")
    }

    /// Storage key pins to the documented app-prefix scheme. Drift
    /// would orphan every existing user's saved preference.
    func test_storageKey_isStable() {
        XCTAssertEqual(AppearanceMode.storageKey, "com.scalinity.stir.appearance.mode")
    }

    // MARK: - Display surface

    func test_displayName_isNonEmptyAndDistinctPerCase() {
        let names = Set(AppearanceMode.allCases.map(\.displayName))
        XCTAssertEqual(names.count, AppearanceMode.allCases.count, "every mode needs a distinct picker label")
        for name in names {
            XCTAssertFalse(name.isEmpty)
        }
    }

    // MARK: - Identity + iteration

    /// `Identifiable` / `CaseIterable` are load-bearing for the
    /// `ForEach(AppearanceMode.allCases)` picker — a future
    /// conformance regression would break the chip row silently.
    func test_allCases_coversThreeModes() {
        XCTAssertEqual(AppearanceMode.allCases, [.system, .light, .dark])
    }

    func test_id_matchesRawValue() {
        for mode in AppearanceMode.allCases {
            XCTAssertEqual(mode.id, mode.rawValue)
        }
    }
}
