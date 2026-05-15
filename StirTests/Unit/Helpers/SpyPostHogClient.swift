// SpyPostHogClient — shared test double for the PostHog telemetry client.
//
// SCA-417: hoisted out of NotificationSchedulerKitTests +
// LeftoversFollowupSchedulerTests where it was defined twice with
// diverging shapes (one used `captures: [Capture]` + NSLock, the
// other used `captured: [Captured]` + main-actor-only access).
// Centralizes on the locked variant so a future non-MainActor caller
// can't silently race.
//
// Uses `PostHogClient`'s DEBUG-only `init(testingOnly: Bool)` seam so
// the production singleton stays isolated. Override is
// signature-compatible with the production `capture(_:properties:)`.
//
// Usage:
//   let spy = SpyPostHogClient()
//   let store = NotificationHistoryStore(..., telemetry: spy)
//   ...
//   XCTAssertEqual(spy.captures.first?.event, .somethingFired)

import Foundation
@testable import Stir

final class SpyPostHogClient: PostHogClient, @unchecked Sendable {
    struct Capture {
        let event: TelemetryEvent
        let properties: [String: Any]
    }

    private let lock = NSLock()
    private var _captures: [Capture] = []

    var captures: [Capture] {
        lock.lock()
        defer { lock.unlock() }
        return _captures
    }

    init() {
        super.init(testingOnly: true)
    }

    override func capture(_ event: TelemetryEvent, properties: [String: Any] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        _captures.append(Capture(event: event, properties: properties))
    }
}
