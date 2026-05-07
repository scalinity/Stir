// ScanFlashModeTests
//
// SCA-47 — verifies the small `ScanFlashMode` enum behind the scan
// camera's flash toggle: cycle order, AVFoundation mapping, and the
// raw-string telemetry contract that ships in `scan_started.flash_mode`
// (CLAUDE.md telemetry section + Spec §15).

import AVFoundation
import XCTest
@testable import Stir

final class ScanFlashModeTests: XCTestCase {
    // MARK: - Cycle order

    /// SCA-47 cycle: off → on → auto → off. Each tap escalates from
    /// "no flash" toward "always flash" then "smart flash" before
    /// returning to the SCA-39-default home position.
    func test_next_cyclesOffToOnToAutoToOff() {
        XCTAssertEqual(ScanFlashMode.off.next(), .on)
        XCTAssertEqual(ScanFlashMode.on.next(), .auto)
        XCTAssertEqual(ScanFlashMode.auto.next(), .off)
    }

    func test_next_fullCycleReturnsToStart() {
        let after3 = ScanFlashMode.off.next().next().next()
        XCTAssertEqual(after3, .off, "3 cycles must return to the starting state")
    }

    // MARK: - AVFoundation mapping

    /// CameraService.capturePhoto(flashMode:) takes
    /// AVCaptureDevice.FlashMode; the user-facing enum maps 1:1 onto
    /// the AVFoundation enum so the camera receives the correct mode.
    func test_avFlashMode_mapsEachCase() {
        XCTAssertEqual(ScanFlashMode.off.avFlashMode, .off)
        XCTAssertEqual(ScanFlashMode.on.avFlashMode, .on)
        XCTAssertEqual(ScanFlashMode.auto.avFlashMode, .auto)
    }

    // MARK: - Telemetry contract

    /// `scan_started.flash_mode` ships these exact strings to PostHog.
    /// Changing them is a wire-contract change — must update CLAUDE.md
    /// telemetry section + Spec §15 in lockstep with this test.
    func test_rawValue_matchesTelemetryContract() {
        XCTAssertEqual(ScanFlashMode.off.rawValue, "off")
        XCTAssertEqual(ScanFlashMode.on.rawValue, "on")
        XCTAssertEqual(ScanFlashMode.auto.rawValue, "auto")
    }

    /// Round-trip rawValue through init so @AppStorage's
    /// RawRepresentable persistence path is exercised — a UserDefaults
    /// read returning a stored "auto" must decode to .auto.
    func test_initFromRawValue_roundTrips() {
        XCTAssertEqual(ScanFlashMode(rawValue: "off"), .off)
        XCTAssertEqual(ScanFlashMode(rawValue: "on"), .on)
        XCTAssertEqual(ScanFlashMode(rawValue: "auto"), .auto)
        XCTAssertNil(ScanFlashMode(rawValue: "AUTO"), "case-sensitive — uppercase shouldn't match")
        XCTAssertNil(ScanFlashMode(rawValue: "always"), "unknown raw values must not silently coerce")
    }

    // MARK: - SF Symbol mapping

    /// The toggle button reads `sfSymbol` for its Image content. Spot-
    /// check that each mode resolves to a non-empty system symbol name
    /// — the literal strings are intentional UX choices and a smoke
    /// test catches accidental drift to the wrong family.
    func test_sfSymbol_returnsBoltVariantPerCase() {
        XCTAssertTrue(ScanFlashMode.off.sfSymbol.contains("bolt"))
        XCTAssertTrue(ScanFlashMode.off.sfSymbol.contains("slash"))
        XCTAssertTrue(ScanFlashMode.on.sfSymbol.hasPrefix("bolt"))
        XCTAssertFalse(ScanFlashMode.on.sfSymbol.contains("slash"))
        XCTAssertTrue(ScanFlashMode.auto.sfSymbol.contains("automatic"))
    }

    // MARK: - Accessibility

    func test_accessibilityLabel_isNonEmptyAndDistinctPerCase() {
        let labels = Set([
            ScanFlashMode.off.accessibilityLabel,
            ScanFlashMode.on.accessibilityLabel,
            ScanFlashMode.auto.accessibilityLabel,
        ])
        XCTAssertEqual(labels.count, 3, "every mode must have a distinct VoiceOver label")
        for label in labels {
            XCTAssertFalse(label.isEmpty)
        }
    }
}
