// RealtimeSessionPreMintTests
//
// P1-P test suite. Pins the four lifecycle cases of
// `RealtimeSession.consumePreMintedTaskIfFresh` plus a seam-integration
// test that verifies `kickOffPreMintIfBudgetAllows` reaches the real
// `AIDispatch.realtimeSession` call path via MockURLProtocol. See
// CLAUDE.md §Deferred "Voice-path test coverage expansion" for the
// P1-P rationale.
//
// Lifecycle cases (tests 1-4) drive state deterministically via the
// `_testSetPreMintTask` harness hook (RealtimeSession.swift `#if DEBUG`
// block) — no network I/O, no timing sensitivity. The integration test
// (test 5, commit 6) uses MockURLProtocol + SupabaseSessionClient's
// `urlSession:` seam to exercise the real AIDispatch path without
// hitting the network.
//
// Defense in depth: lifecycle tests use a `FailFastURLProtocol`-backed
// URLSession in `makeDriver()`. Tests 1-4 should never issue an HTTP
// request — the task is injected directly. If a future refactor
// accidentally routes consume or prewarm through HTTP, the fail-fast
// protocol surfaces it immediately instead of silently passing.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class RealtimeSessionPreMintTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var recipePlan: RecipePlan!
    private var cookingSession: CookingSession!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        household = try HouseholdProfileRepository(controller: controller)
            .ensureHouseholdProfile(for: "install:premint-\(UUID().uuidString)")
        let ctx = controller.viewContext
        recipePlan = RecipePlan(context: ctx)
        recipePlan.id = UUID()
        recipePlan.household = household
        recipePlan.title = "Test"
        recipePlan.servings = 2
        recipePlan.estimatedMinutes = 10
        recipePlan.typedOrigin = .ai
        recipePlan.createdAt = Date()
        recipePlan.updatedAt = Date()
        try controller.save()
        cookingSession = try CookingSessionRepository(controller: controller)
            .createSession(on: household, for: recipePlan, entryPoint: .solve)
    }

    // MARK: - P1-P.1 — close-before-consume

    /// The close-before-consume invariant: when `session.close()` cancels
    /// the pending pre-mint task and clears the slot as part of its
    /// teardown, a subsequent consume is a clean no-op AND the task
    /// itself is dead.
    ///
    /// This test exercises the extracted teardown method
    /// `cancelAndClearPreMintSlot()` via the `_testTearDownPreMintSlot()`
    /// hook — NOT `_testSetPreMintTask(nil, nil)`, which would simulate
    /// teardown instead of exercising it. The hook calls the same symbol
    /// `close()` calls, so a future refactor that changes the teardown
    /// logic inside `cancelAndClearPreMintSlot()` is caught here. The
    /// paired wiring test (test 2 below) catches the orthogonal failure
    /// mode where the call is removed from `close()`.
    func test_preMintTask_closeBeforeConsume_returnsNilAndCancels() async throws {
        let session = makeDriver()
        let sentinel = Task<RealtimeSessionResponse, Error> {
            try await Task.sleep(for: .seconds(60))
            XCTFail("sentinel should have been cancelled before completing")
            throw CancellationError()
        }
        session._testSetPreMintTask(sentinel, startedAt: Date())
        XCTAssertTrue(
            session._testPendingPreMintIsSet,
            "slot must be set before close-teardown",
        )

        // Act: run the production teardown path
        // (cancelAndClearPreMintSlot). NOT _testSetPreMintTask(nil, nil)
        // — that would simulate close instead of exercising it. This
        // call is the actual invariant under test.
        session._testTearDownPreMintSlot()

        // Assert teardown behavior:
        XCTAssertFalse(session._testPendingPreMintIsSet, "slot must be empty post-teardown")
        XCTAssertNil(session._testPendingPreMintStartedAt, "timestamp must be nil post-teardown")
        do {
            _ = try await sentinel.value
            XCTFail("sentinel must be cancelled; .value should throw")
        } catch is CancellationError {
            // expected — cancel arrived before sleep completed
        } catch {
            XCTFail("sentinel threw unexpected error: \(error)")
        }

        // Subsequent consume returns nil via guard-1 (empty slot) —
        // safe after teardown.
        XCTAssertNil(
            session._testConsumePreMintedTaskIfFresh(),
            "consume after teardown must return nil",
        )
    }

    // MARK: - P1-P.1b — close wiring (extraction is invoked)

    /// Pairs with test 1 above. Test 1 pins `cancelAndClearPreMintSlot()`
    /// behavior via the hook; this test pins that `close()` actually
    /// invokes the extracted method. Together they catch both refactor
    /// failure modes: (a) teardown logic moves out of the extracted
    /// method (test 1 catches), and (b) the call site is removed from
    /// `close()` (this test catches).
    ///
    /// Calls `close()` directly on a fresh `makeDriver()` session — safe
    /// because every other field `close()` touches (pendingReport,
    /// continuations, transport, audioPipeline, etc.) is nil on an
    /// unopened session. See `RealtimeSession.close()` for the full
    /// teardown sequence.
    func test_close_invokesCancelAndClearPreMintSlot() async throws {
        let session = makeDriver()
        let sentinel = Task<RealtimeSessionResponse, Error> {
            try await Task.sleep(for: .seconds(60))
            XCTFail("sentinel should have been cancelled before completing")
            throw CancellationError()
        }
        session._testSetPreMintTask(sentinel, startedAt: Date())
        XCTAssertTrue(session._testPendingPreMintIsSet, "precondition: slot set")

        // Act: close the session directly. Exercises the production
        // call to cancelAndClearPreMintSlot inside close's teardown.
        session.close()

        // Assert the pre-mint slot was torn down as part of close:
        XCTAssertFalse(session._testPendingPreMintIsSet, "slot must be cleared by close")
        XCTAssertNil(session._testPendingPreMintStartedAt, "timestamp must be cleared by close")
        do {
            _ = try await sentinel.value
            XCTFail("sentinel must be cancelled by close")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("sentinel threw unexpected error: \(error)")
        }
    }

    // MARK: - P1-P.2 — ready-before-refresh

    /// Happy path: a pre-mint task has completed successfully BEFORE
    /// consume is called, within the 45 s staleness budget. Consume
    /// must return the ready task; the caller awaits `.value` and
    /// receives the pre-minted `RealtimeSessionResponse`. Post-consume
    /// the slot must be cleared via the consumer's defer (state
    /// hygiene — a subsequent call would return nil via guard-1).
    ///
    /// Baseline for the P1-P suite. The remaining three tests
    /// (staleness, in-flight-await, seam) all assume this path works;
    /// if the happy path is broken, the other tests can't reliably
    /// pin their invariants.
    func test_preMintTask_readyBeforeRefresh_returnsTask() async throws {
        let session = makeDriver()
        let stubSessionID = UUID().uuidString

        // Task<T, Error>'s body runs on creation; by the time
        // `_testSetPreMintTask` returns, `.value` is already resolved.
        let ready = Task<RealtimeSessionResponse, Error> {
            RealtimeSessionResponse(
                authToken: "auth_tokens/test-ready",
                expiresAt: "2027-01-01T00:00:00Z",
                sessionID: stubSessionID,
                wsURL: "wss://test.invalid",
                promptVersion: "1.0.0",
                setupFrameJSON: "{\"setup\":{}}",
            )
        }
        session._testSetPreMintTask(ready, startedAt: Date())
        XCTAssertTrue(session._testPendingPreMintIsSet, "precondition: slot set")

        // Act: consume well within the 45 s budget — consumer should
        // return the ready task via the fresh branch.
        let consumed = session._testConsumePreMintedTaskIfFresh()
        let result = try await XCTUnwrap(consumed).value

        // Assert: caller receives the pre-minted response.
        XCTAssertEqual(
            result.sessionID,
            stubSessionID,
            "consume must return the pre-minted response unchanged",
        )

        // Assert: consumer's defer cleared state — subsequent consume
        // on the same session would return nil via guard-1.
        XCTAssertFalse(
            session._testPendingPreMintIsSet,
            "slot must be cleared post-consume",
        )
        XCTAssertNil(
            session._testPendingPreMintStartedAt,
            "timestamp must be cleared post-consume",
        )
        XCTAssertNil(
            session._testConsumePreMintedTaskIfFresh(),
            "re-consume on cleared slot must return nil",
        )
    }

    // MARK: - Helpers

    /// Builds a `RealtimeSession` routed through a `FailFastURLProtocol`-
    /// backed URLSession. Lifecycle tests (1-4) never trigger a real mint
    /// — tasks are injected directly via `_testSetPreMintTask`. If a
    /// future refactor accidentally routes consume or prewarm through
    /// HTTP, the fail-fast protocol surfaces it via XCTFail. The
    /// integration test (5, commit 6) uses a sibling helper that routes
    /// through MockURLProtocol for scripted responses.
    private func makeDriver() -> RealtimeSession {
        let config = AppConfig(
            supabase: AppConfig.Supabase(url: URL(string: "https://test.invalid")!, anonKey: "x"),
            posthog: nil, sentry: nil, revenueCat: nil,
            build: "1.0.0 (1)", osVersion: "17.5",
        )
        let sessionClient = SupabaseSessionClient(
            config: config,
            keychain: MockKeychain(),
            urlSession: Self.failFastSession(),
            sentry: NoOpSentryReporter(),
        )
        let aiDispatch = AIDispatch(session: sessionClient, config: config)
        let mint = RealtimeSessionResponse(
            authToken: "auth_tokens/test",
            expiresAt: "2027-01-01T00:00:00Z",
            sessionID: UUID().uuidString,
            wsURL: "wss://test.invalid",
            promptVersion: "1.0.0",
            setupFrameJSON: "{\"setup\":{}}",
        )
        return RealtimeSession(
            testingOnlyMintResponse: mint,
            aiDispatch: aiDispatch,
            voiceTurnRepository: VoiceTurnRepository(controller: controller),
            cookingSession: cookingSession,
        )
    }

    /// URLSession routed through FailFastURLProtocol. Any HTTP request
    /// issued during a lifecycle test XCTFails immediately.
    private static func failFastSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailFastURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - FailFastURLProtocol

/// URLProtocol that XCTFails on any HTTP request. Defense in depth for
/// P1-P lifecycle tests (1-4), which never trigger real mint — tasks
/// are injected directly via `_testSetPreMintTask`. If a future refactor
/// accidentally routes consume or prewarm through HTTP, this surfaces
/// the regression instead of silently passing. File-private to
/// RealtimeSessionPreMintTests for now — promote to a shared test
/// utility if P1-Q / P1-N / P1-O end up wanting the same assertion.
private final class FailFastURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("lifecycle test issued HTTP request: \(request.url?.absoluteString ?? "?")")
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
