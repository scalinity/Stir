// NotificationPreferencesStoreTests
//
// Unit tests for the local notification-prefs store. Each test runs
// against an isolated UserDefaults suite so state never leaks across
// tests or into the shared App Group.

import XCTest
@testable import Stir

@MainActor
final class NotificationPreferencesStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: NotificationPreferencesStore!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.notifprefs.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = NotificationPreferencesStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Defaults

    func test_freshInstall_opensInToAllTypes() {
        // Opt-in UX — unset keys should read as `true` so new users
        // receive cook + import notifications by default.
        let prefs = store.preferences
        XCTAssertTrue(prefs.reactivation)
        XCTAssertTrue(prefs.importCompletion)
    }

    // MARK: - Setters

    func test_setReactivation_persistsFalse() {
        store.setReactivation(false)
        XCTAssertFalse(store.preferences.reactivation)
    }

    func test_setImportCompletion_persistsFalse() {
        store.setImportCompletion(false)
        XCTAssertFalse(store.preferences.importCompletion)
    }

    func test_togglingOne_doesNotAffectOthers() {
        store.setReactivation(false)
        let prefs = store.preferences
        XCTAssertFalse(prefs.reactivation)
        XCTAssertTrue(prefs.importCompletion, "import unaffected by reactivation toggle")
    }

    // MARK: - Bulk replace

    func test_replace_updatesBoth() {
        let input = NotificationPreferencesStore.Preferences(
            reactivation: false,
            importCompletion: false,
        )
        store.replace(with: input)
        let out = store.preferences
        XCTAssertFalse(out.reactivation)
        XCTAssertFalse(out.importCompletion)
    }
}
