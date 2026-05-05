// RootCoordinatorIdentityTransitionTests
//
// CR3-C1 fix: pin every row of the identity-transition table that
// `applyPostHogIdentityTransition` arbitrates. The table is the
// `voice_conversion_event` funnel contract — getting any branch wrong
// fragments per-user attribution across the install:→ck: migration.
//
// We also pin SDK call ORDER on the install→ck branch:
//   alias(newKey) MUST precede identify(newKey)
// per PostHog SDK semantics — alias ties the CURRENT distinct_id to
// the alias argument; calling identify first would attach the alias
// to the wrong person.
//
// Sentry breadcrumb assertions cover CR3-W5: the prior StubSentry
// silently dropped breadcrumbs, so a refactor that drops the emit
// could ship green. Recording variant captures both posthog_alias_forward
// and posthog_reset_on_user_flip events.

import Foundation
import XCTest
@testable import Stir

@MainActor
final class RootCoordinatorIdentityTransitionTests: XCTestCase {
    private var client: RecordingPostHogClient!
    private var sentry: RecordingSentryReporter!
    private var coordinator: RootCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        client = RecordingPostHogClient()
        sentry = RecordingSentryReporter()
        coordinator = makeCoordinator(sentry: sentry)
    }

    override func tearDown() async throws {
        client = nil
        sentry = nil
        coordinator = nil
        try await super.tearDown()
    }

    // MARK: - Transition table: nil → any

    func test_nilPrevious_callsIdentifyOnly() {
        coordinator.applyPostHogIdentityTransition(
            previousKey: nil,
            newKey: "ck:_AAA",
            newKeyHash: "h-new",
            client: client,
        )
        XCTAssertEqual(client.calls, [.identify("h-new")])
        XCTAssertTrue(sentry.breadcrumbs.isEmpty, "First-launch path emits no breadcrumb.")
    }

    func test_emptyStringPrevious_treatedAsNil() {
        coordinator.applyPostHogIdentityTransition(
            previousKey: "",
            newKey: "ck:_AAA",
            newKeyHash: "h-new",
            client: client,
        )
        XCTAssertEqual(client.calls, [.identify("h-new")])
    }

    // MARK: - Transition table: same → same

    func test_samePrevious_identifiesNoOp() {
        coordinator.applyPostHogIdentityTransition(
            previousKey: "ck:_AAA",
            newKey: "ck:_AAA",
            newKeyHash: "h-aaa",
            client: client,
        )
        XCTAssertEqual(client.calls, [.identify("h-aaa")])
        XCTAssertTrue(sentry.breadcrumbs.isEmpty, "Same-key refresh path emits no breadcrumb.")
    }

    // MARK: - Transition table: install:X → ck:Y

    func test_installToCk_aliasesBEFOREIdentify() {
        coordinator.applyPostHogIdentityTransition(
            previousKey: "install:abc-123",
            newKey: "ck:_DEF",
            newKeyHash: "h-def",
            client: client,
        )
        // SDK call order: alias FIRST, identify SECOND. CR3-C1 invariant.
        XCTAssertEqual(
            client.calls,
            [.alias("h-def"), .identify("h-def")],
            "alias must precede identify so PostHog ties the alias to the previous-key person.",
        )
        XCTAssertEqual(sentry.breadcrumbs.count, 1)
        XCTAssertEqual(sentry.breadcrumbs.first?.message, "posthog_alias_forward")
        XCTAssertEqual(sentry.breadcrumbs.first?.data["new_hash"], "h-def")
    }

    // MARK: - Transition table: ck:X → ck:Y (genuine user flip)

    func test_ckToCk_resetsThenIdentifies() {
        coordinator.applyPostHogIdentityTransition(
            previousKey: "ck:_AAA",
            newKey: "ck:_BBB",
            newKeyHash: "h-bbb",
            client: client,
        )
        XCTAssertEqual(client.calls, [.reset, .identify("h-bbb")])
        XCTAssertEqual(sentry.breadcrumbs.first?.message, "posthog_reset_on_user_flip")
    }

    // MARK: - Transition table: ck:X → install:Y

    func test_ckToInstall_resetsThenIdentifies() {
        coordinator.applyPostHogIdentityTransition(
            previousKey: "ck:_AAA",
            newKey: "install:abc-123",
            newKeyHash: "h-install",
            client: client,
        )
        XCTAssertEqual(client.calls, [.reset, .identify("h-install")])
        XCTAssertEqual(sentry.breadcrumbs.first?.message, "posthog_reset_on_user_flip")
    }

    // MARK: - Transition table: install:X → install:Y

    func test_installToInstall_resetsThenIdentifies() {
        // Fresh install rolled its installation UUID — should reset, not alias.
        coordinator.applyPostHogIdentityTransition(
            previousKey: "install:abc-123",
            newKey: "install:def-456",
            newKeyHash: "h-new-install",
            client: client,
        )
        XCTAssertEqual(client.calls, [.reset, .identify("h-new-install")])
        XCTAssertEqual(sentry.breadcrumbs.first?.message, "posthog_reset_on_user_flip")
    }

    // MARK: - Negative: alias does NOT fire on same-prefix-different-value
    // when prev is ck and new is ck (no install→ck pattern).

    func test_ckToCk_doesNotAlias() {
        coordinator.applyPostHogIdentityTransition(
            previousKey: "ck:_AAA",
            newKey: "ck:_BBB",
            newKeyHash: "h-bbb",
            client: client,
        )
        XCTAssertFalse(client.calls.contains(where: {
            if case .alias = $0 { return true } else { return false }
        }), "ck→ck must NEVER alias — that would falsely merge two distinct iCloud personas.")
    }

    // MARK: - Helper

    /// Minimal coordinator for transition-only tests. The transition
    /// function only needs the coordinator's `sentry` reference; every
    /// other dependency stays at its default. We reuse
    /// `RootCoordinatorFastPathTests`'s config + sessionClient pattern
    /// to satisfy the required parameters.
    private func makeCoordinator(sentry: any SentryReporting) -> RootCoordinator {
        let config = AppConfig(
            supabase: AppConfig.Supabase(
                url: URL(string: "https://test.supabase.co")!,
                anonKey: "test-anon",
            ),
            posthog: nil,
            sentry: nil,
            revenueCat: nil,
            build: "test (0)",
            osVersion: "26.0",
        )
        return RootCoordinator(
            config: config,
            sentry: sentry,
            sessionClient: SupabaseSessionClient(
                config: config,
                keychain: MockKeychain(),
            ),
        )
    }
}

// MARK: - Recording test doubles

/// Subclasses PostHogClient and overrides identify/alias/reset to record
/// the ordered call sequence. PostHogClient's `init(testingOnly: Bool)`
/// is DEBUG-only and the only init available to subclasses.
final class RecordingPostHogClient: PostHogClient {
    enum Call: Equatable {
        case identify(String)
        case alias(String)
        case reset
    }
    private(set) var calls: [Call] = []

    init() { super.init(testingOnly: true) }

    override func identify(distinctID: String) {
        calls.append(.identify(distinctID))
    }
    override func alias(to newDistinctID: String) {
        calls.append(.alias(newDistinctID))
    }
    override func reset() {
        calls.append(.reset)
    }
}

final class RecordingSentryReporter: SentryReporting, @unchecked Sendable {
    struct Breadcrumb {
        let category: String
        let message: String
        let data: [String: String]
    }
    private(set) var breadcrumbs: [Breadcrumb] = []

    func captureError(_: any Error, context _: [String: String]) {}
    func breadcrumb(category: String, message: String, data: [String: String]) {
        breadcrumbs.append(Breadcrumb(category: category, message: message, data: data))
    }
    func setUserContext(keyHash _: String) {}
}
