// TutorialManagerTests
//
// Visibility / completion / replay rules for the in-app tutorial
// system (SCA-5). Each test runs against an isolated UserDefaults
// suite so state never leaks across tests or into `.standard` —
// matches the pattern in `NotificationPreferencesStoreTests`.

import XCTest
@testable import Stir

final class TutorialManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var manager: TutorialManager!
    private var suiteName: String!

    @MainActor
    override func setUp() {
        super.setUp()
        suiteName = "test.tutorialmanager.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        manager = TutorialManager(defaults: defaults, sentry: NoOpSentryReporter())
    }

    @MainActor
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        manager = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Visibility rule (the core gating logic)

    @MainActor
    func test_freshInstall_isNotCompleted() {
        XCTAssertFalse(manager.isCompleted(.tonightTour))
    }

    @MainActor
    func test_completedKeys_emptyOnFreshInstall() {
        XCTAssertTrue(manager.completedKeys.isEmpty)
    }

    @MainActor
    func test_markCompleted_persistsAcrossManagerInstances() {
        manager.markCompleted(.tonightTour)

        // Cold-launch simulation: re-instantiate against the same
        // UserDefaults suite. The new manager must hydrate the
        // completion flag from disk on init.
        let fresh = TutorialManager(defaults: defaults, sentry: NoOpSentryReporter())
        XCTAssertTrue(fresh.isCompleted(.tonightTour))
        XCTAssertTrue(fresh.completedKeys.contains(.tonightTour))
    }

    // MARK: - Completion / dismissal both terminate

    @MainActor
    func test_skip_andComplete_areBothTerminal() {
        // The tutorial flow's `onSkip` and `onComplete` both call
        // `markCompleted` — the manager treats them identically (single
        // boolean flag, no third state).
        manager.markCompleted(.tonightTour)
        XCTAssertTrue(manager.isCompleted(.tonightTour))

        manager.markCompleted(.tonightTour)
        XCTAssertTrue(manager.isCompleted(.tonightTour))
    }

    @MainActor
    func test_markCompleted_isIdempotent() {
        manager.markCompleted(.tonightTour)
        manager.markCompleted(.tonightTour)
        manager.markCompleted(.tonightTour)
        XCTAssertTrue(manager.isCompleted(.tonightTour))
        XCTAssertEqual(manager.completedKeys.count, 1)
    }

    // MARK: - Settings replay

    @MainActor
    func test_reset_clearsCompletion() {
        manager.markCompleted(.tonightTour)
        XCTAssertTrue(manager.isCompleted(.tonightTour))

        manager.reset(.tonightTour)
        XCTAssertFalse(manager.isCompleted(.tonightTour))
        XCTAssertFalse(manager.completedKeys.contains(.tonightTour))
    }

    @MainActor
    func test_reset_returnsToFreshInstallState() {
        // After mark+reset, the manager state must be observably
        // identical to a fresh install — this is the contract the
        // Settings replay flow depends on.
        manager.markCompleted(.tonightTour)
        manager.reset(.tonightTour)

        XCTAssertFalse(manager.isCompleted(.tonightTour))
        XCTAssertTrue(manager.completedKeys.isEmpty)
        XCTAssertFalse(defaults.bool(forKey: TutorialKey.tonightTour.defaultsKey))
    }

    @MainActor
    func test_replayCycle_canMarkAgainAfterReset() {
        // Full replay cycle: complete → reset → complete. Each
        // markCompleted writes both UserDefaults and the in-memory
        // mirror; the cycle must end in completed state.
        manager.markCompleted(.tonightTour)
        manager.reset(.tonightTour)
        XCTAssertFalse(manager.isCompleted(.tonightTour))

        manager.markCompleted(.tonightTour)
        XCTAssertTrue(manager.isCompleted(.tonightTour))
    }

    // MARK: - Defaults isolation (regression guards)

    @MainActor
    func test_managerWritesNamespacedKey() {
        manager.markCompleted(.tonightTour)
        XCTAssertEqual(
            TutorialKey.tonightTour.defaultsKey,
            "stir.tutorial.completed.tonight_tour",
        )
        XCTAssertTrue(defaults.bool(forKey: "stir.tutorial.completed.tonight_tour"))
    }

    @MainActor
    func test_resetAlsoClearsUserDefaults() {
        // The in-memory mirror and the on-disk flag must agree —
        // otherwise a cold launch reads stale state from disk and
        // un-does the reset.
        manager.markCompleted(.tonightTour)
        XCTAssertTrue(defaults.bool(forKey: TutorialKey.tonightTour.defaultsKey))

        manager.reset(.tonightTour)
        XCTAssertFalse(defaults.bool(forKey: TutorialKey.tonightTour.defaultsKey))
    }

    // MARK: - TutorialKey display + telemetry contract

    @MainActor
    func test_telemetryID_isSnakeCase() {
        // PostHog `tutorial_id` property is snake_case. Guards a future
        // enum case from shipping with a CamelCase rawValue that would
        // silently break dashboards.
        for key in TutorialKey.allCases {
            XCTAssertEqual(
                key.telemetryID,
                key.rawValue,
                "telemetryID should equal rawValue (\(key))",
            )
            XCTAssertFalse(
                key.telemetryID.contains(" "),
                "telemetryID must not contain spaces (\(key))",
            )
            XCTAssertEqual(
                key.telemetryID.lowercased(),
                key.telemetryID,
                "telemetryID must be lowercase (\(key))",
            )
        }
    }

    @MainActor
    func test_displayName_isUserFacing() {
        for key in TutorialKey.allCases {
            XCTAssertFalse(key.displayName.isEmpty)
            XCTAssertNotEqual(
                key.displayName,
                key.rawValue,
                "displayName must be user-facing, not the raw value (\(key))",
            )
        }
    }

    @MainActor
    func test_replaySubtitle_isPresent() {
        // Settings copy renders `displayName` and `replaySubtitle`
        // side by side; both must be non-empty for every key.
        for key in TutorialKey.allCases {
            XCTAssertFalse(key.replaySubtitle.isEmpty)
        }
    }

    // MARK: - DEBUG resetAll

    #if DEBUG
    @MainActor
    func test_resetAll_clearsAllKeys() {
        for key in TutorialKey.allCases {
            manager.markCompleted(key)
        }
        XCTAssertEqual(manager.completedKeys.count, TutorialKey.allCases.count)

        manager.resetAll()
        XCTAssertTrue(manager.completedKeys.isEmpty)
        for key in TutorialKey.allCases {
            XCTAssertFalse(defaults.bool(forKey: key.defaultsKey))
        }
    }
    #endif
}
