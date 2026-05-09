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

    override func tearDown() async throws {
        // Clear any handler set by the seam integration test (P1-P.5).
        // Lifecycle tests don't set it, so this is a no-op for them.
        MockURLProtocol.reset()
        try await super.tearDown()
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
            MockMintResponse.make(sessionID: stubSessionID)
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

    // MARK: - P1-P.3 — staleness boundary (both sides)

    /// Fresh side of the 45 s staleness boundary. A task with a
    /// `startedAt` timestamp 1 s INSIDE the budget must be returned by
    /// consume (fresh branch). Paired with the stale-side test below:
    /// together they catch a refactor that flips the comparison
    /// direction (e.g., `<` → `>`) — both tests fail, identifying the
    /// flip. Neither test pins `<` vs `<=` at age == exactly
    /// `preMintStalenessSec`; that requires time-injection support
    /// not yet present on the consumer, out of scope for P1-P.
    ///
    /// Uses `LiveSessionBudget.preMintStalenessSec` directly so the
    /// tests survive a future bump of the constant — the 1 s margin
    /// is relative to whatever the budget is, not to the hard-coded
    /// 45 s.
    func test_preMintTask_justUnderStalenessBoundary_returnsTask() async throws {
        let session = makeDriver()
        let stubSessionID = UUID().uuidString
        let ready = Task<RealtimeSessionResponse, Error> {
            MockMintResponse.make(
                authToken: "auth_tokens/test-boundary-fresh",
                sessionID: stubSessionID,
            )
        }
        let staleBoundary = LiveSessionBudget.preMintStalenessSec
        // startedAt 1 s INSIDE the budget — age at consume is ~(budget-1)
        // with room for ~1 s of test-execution drift before flipping stale.
        let startedAt = Date().addingTimeInterval(-(staleBoundary - 1))
        session._testSetPreMintTask(ready, startedAt: startedAt)

        // Act:
        let consumed = session._testConsumePreMintedTaskIfFresh()

        // Assert fresh branch returned the task + defer cleared state.
        let result = try await XCTUnwrap(consumed).value
        XCTAssertEqual(
            result.sessionID,
            stubSessionID,
            "fresh-boundary consume must return the pre-minted response",
        )
        XCTAssertFalse(
            session._testPendingPreMintIsSet,
            "defer must clear slot even on fresh return",
        )
    }

    /// Stale side of the 45 s staleness boundary. A task with a
    /// `startedAt` timestamp 1 s OUTSIDE the budget must be cancelled
    /// AND the consumer must return nil. The cancel is load-bearing:
    /// if stale tasks leak, the backend mint completes in the
    /// background, wastes a mint request, and holds a Gemini
    /// auth_tokens resource until it naturally expires.
    func test_preMintTask_stalenessBeyond45s_returnsNilAndCancels() async throws {
        let session = makeDriver()
        let sentinel = Task<RealtimeSessionResponse, Error> {
            try await Task.sleep(for: .seconds(60))
            XCTFail("sentinel should have been cancelled by staleness branch")
            throw CancellationError()
        }
        let staleBoundary = LiveSessionBudget.preMintStalenessSec
        // startedAt 1 s PAST the budget — clearly stale by the time
        // consume runs, robust to test-execution drift.
        let startedAt = Date().addingTimeInterval(-(staleBoundary + 1))
        session._testSetPreMintTask(sentinel, startedAt: startedAt)

        // Act: consume must hit the staleness branch.
        let consumed = session._testConsumePreMintedTaskIfFresh()

        // Assert nil return + slot cleared.
        XCTAssertNil(consumed, "stale consume must return nil")
        XCTAssertFalse(
            session._testPendingPreMintIsSet,
            "slot must be cleared after stale-branch consumption",
        )
        XCTAssertNil(
            session._testPendingPreMintStartedAt,
            "timestamp must be cleared after stale-branch consumption",
        )

        // Assert the task was cancelled — NOT leaked-running. If this
        // fails, the backend mint will still complete and waste a
        // Gemini auth_tokens resource.
        do {
            _ = try await sentinel.value
            XCTFail("staleness branch must cancel the task, not leak it")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("sentinel threw unexpected error: \(error)")
        }
    }

    func test_preMintTask_exactStalenessBoundary_returnsNilAndCancels() async throws {
        let baseline = Date(timeIntervalSinceReferenceDate: 10_000)
        let session = makeDriver(now: {
            baseline.addingTimeInterval(LiveSessionBudget.preMintStalenessSec)
        })
        let sentinel = Task<RealtimeSessionResponse, Error> {
            try await Task.sleep(for: .seconds(60))
            XCTFail("sentinel should have been cancelled at the exact staleness boundary")
            throw CancellationError()
        }
        session._testSetPreMintTask(sentinel, startedAt: baseline)

        let consumed = session._testConsumePreMintedTaskIfFresh()

        XCTAssertNil(consumed, "age == preMintStalenessSec must be stale because production uses a strict fresh-age comparison")
        XCTAssertFalse(session._testPendingPreMintIsSet, "slot must clear after exact-boundary stale discard")
        XCTAssertNil(session._testPendingPreMintStartedAt, "timestamp must clear after exact-boundary stale discard")
        do {
            _ = try await sentinel.value
            XCTFail("exact-boundary stale discard must cancel the task")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("sentinel threw unexpected error: \(error)")
        }
    }

    // MARK: - P1-P.4 — in-flight-await (Behavior A contract)

    /// The in-flight case: consume is called while the pre-mint task is
    /// still running. Consumer returns the Task regardless of completion
    /// state (Behavior A — the consumer does NOT inspect task state,
    /// only slot occupancy and age); the defer clears the slot
    /// atomically with the return even though the task hasn't resolved
    /// yet; the caller's subsequent `await task.value` suspends until
    /// the task resolves naturally.
    ///
    /// Pins Behavior A. A future refactor that adds a completion check
    /// and returns nil for in-flight tasks (Behavior B — skip in-flight,
    /// re-mint) would break this test — correctly, because that's a
    /// contract change, not a refactor.
    ///
    /// Uses `AsyncThrowingStream.makeStream()` to expose the task's
    /// resume-control synchronously. Chosen over the continuation-box +
    /// `Task.yield` loop because the stream's continuation is returned
    /// directly from `makeStream()` — no race between "task body starts"
    /// and "continuation captured." The stream buffers yields that
    /// happen before iteration reaches them, so ordering of
    /// `yield` / `finish` / task start is irrelevant.
    func test_preMintTask_inFlightAwait_completesOnRefreshResult() async throws {
        let session = makeDriver()
        let stubSessionID = UUID().uuidString

        let (stream, continuation) = AsyncThrowingStream<RealtimeSessionResponse, Error>.makeStream()
        let inFlight = Task<RealtimeSessionResponse, Error> {
            for try await value in stream {
                return value
            }
            throw CancellationError()
        }

        session._testSetPreMintTask(inFlight, startedAt: Date())

        // Act: consume while the task is still iterating the stream (no
        // value yielded yet). Consumer must return the task, NOT nil.
        let consumed = session._testConsumePreMintedTaskIfFresh()
        let task = try XCTUnwrap(consumed, "in-flight consume must return the task")

        // Assert defer cleared the slot atomically with return, even
        // though the task hasn't resolved.
        XCTAssertFalse(
            session._testPendingPreMintIsSet,
            "defer must clear slot even for still-running task",
        )
        XCTAssertNil(
            session._testPendingPreMintStartedAt,
            "defer must clear timestamp even for still-running task",
        )

        // Resume the task: yield the stub response + finish the stream.
        // Task body's `for try await` loop returns the first yielded
        // value; `continuation.finish()` closes the stream so the
        // implicit `throw CancellationError()` path isn't taken.
        continuation.yield(MockMintResponse.make(
            authToken: "auth_tokens/test-in-flight",
            sessionID: stubSessionID,
            wsURL: "wss://test.invalid",
        ))
        continuation.finish()

        // Caller awaits task.value — resolves to the yielded response.
        let result = try await task.value
        XCTAssertEqual(
            result.sessionID,
            stubSessionID,
            "in-flight task resolves to the response the test yielded",
        )
    }

    // MARK: - P1-P.5 — seam integration (prewarm → AIDispatch → urlSession)

    /// Verifies `kickOffPreMintIfBudgetAllows` reaches the production
    /// `AIDispatch.realtimeSession()` call path through the injected
    /// urlSession. Tests 1-4 pin the consumer's state machine on
    /// synthetic tasks — they don't catch a refactor that silently
    /// routes production around the seam. This test catches that.
    ///
    /// Pins three things, nothing more:
    ///   1. HTTP request is issued through the injected urlSession —
    ///      MockURLProtocol handler fires and its URL/method assertions
    ///      confirm the prewarm hit the realtime-session endpoint.
    ///   2. Response from the urlSession flows into pendingPreMintTask
    ///      synchronously after prewarm returns (slot populated).
    ///   3. The task in the slot resolves to the response the mock
    ///      returned (field-level sessionID match — same pattern as
    ///      tests 3 and 5).
    ///
    /// Does NOT pin: request body correctness, retry behavior, timeout
    /// handling, auth header shape — those are AIDispatch /
    /// SupabaseSessionClient contracts with their own tests. Seam
    /// integration only verifies the seam connects.
    func test_prewarmPreMintTask_setsPendingTask_viaRealAiDispatchSeam() async throws {
        let session = makeDriverWithMockURLProtocol()
        let stubSessionID = UUID().uuidString

        MockURLProtocol.handler = { request in
            // Pin (1) sub-assertion: prewarm must POST to the
            // realtime-session endpoint. Request body correctness is
            // AIDispatch's contract, not pinned here.
            XCTAssertEqual(
                request.url?.path,
                "/functions/v1/realtime-session",
                "prewarm must POST to the realtime-session endpoint",
            )
            XCTAssertEqual(request.httpMethod, "POST", "prewarm must use POST")

            let body = """
            {
                "auth_token": "auth_tokens/seam-test",
                "expires_at": "2027-01-01T00:00:00Z",
                "session_id": "\(stubSessionID)",
                "ws_url": "wss://test.invalid",
                "prompt_version": "1.0.0",
                "setup_frame_json": "{\\"setup\\":{}}"
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["content-type": "application/json"],
            )!
            return (response, body)
        }

        // Act: invoke prewarm. Synchronously stores a Task in the slot;
        // the Task begins the HTTP call in the background.
        session._testKickOffPreMintIfBudgetAllows(currentTurn: 3)

        // Pin (2): slot is populated immediately — prewarm stored a task.
        XCTAssertTrue(
            session._testPendingPreMintIsSet,
            "prewarm must populate pendingPreMintTask",
        )

        // Consume and await the task through the real AIDispatch path.
        let task = try XCTUnwrap(
            session._testConsumePreMintedTaskIfFresh(),
            "slot must hold a task after prewarm",
        )
        let response = try await task.value

        // Pin (3): response the mock returned flows through to the
        // caller unchanged. If the handler was never invoked, the
        // response would fail to decode and `task.value` would throw
        // before reaching this line — so a successful sessionID match
        // here also implicitly proves pin (1)'s URL/method assertions
        // fired and the handler ran.
        XCTAssertEqual(
            response.sessionID,
            stubSessionID,
            "seam must deliver the mocked response unchanged",
        )
    }

    // MARK: - SCA-132 — mock live transport harness

    func test_mockLiveTransport_yieldsSetupCompleteThroughReceiveDispatcher() async throws {
        let session = makeDriver()
        let transport = MockLiveTransport()
        session._testInstallLiveTransport(transport)
        session.startReceiveDispatcher()

        let waiter = Task { @MainActor in
            try await session.awaitSetupComplete(timeoutSec: 1)
        }
        await Task.yield()

        transport.yield(.setupComplete)
        try await waiter.value

        try await transport.send(.setupRawJSON("{\"setup\":{}}"))
        XCTAssertEqual(transport.sentFrames.count, 1, "mock transport must capture outbound frames")
        transport.close()
        XCTAssertTrue(transport.isClosed, "mock transport must record close state")
    }

    // MARK: - SCA-256 (W8 from /review-5) — MockLiveTransport error paths

    /// Pre-fix the mock harness only had a happy-path test; the seam's
    /// value (catching error-path regressions) wasn't exercised. These
    /// three tests pin the contract for `openError`, `sendError`, and
    /// `finish(throwing:)` so a future refactor that swallowed any of
    /// the three propagation paths fails the suite.

    func test_mockLiveTransport_openErrorPropagates() {
        struct OpenStubError: Error, Equatable {}
        let transport = MockLiveTransport()
        transport.openError = OpenStubError()
        XCTAssertThrowsError(
            try transport.open(url: URL(string: "wss://test.invalid")!),
        ) { error in
            XCTAssertTrue(error is OpenStubError, "openError must propagate verbatim")
        }
        XCTAssertTrue(transport.openedURLs.isEmpty, "open(url:) must NOT record on the throw path")
    }

    func test_mockLiveTransport_sendErrorPropagates() async {
        struct SendStubError: Error, Equatable {}
        let transport = MockLiveTransport()
        transport.sendError = SendStubError()
        do {
            try await transport.send(.setupRawJSON("{\"setup\":{}}"))
            XCTFail("send(_:) must throw when sendError is set")
        } catch is SendStubError {
            // expected
        } catch {
            XCTFail("send(_:) must throw the configured sendError, not \(error)")
        }
        XCTAssertTrue(transport.sentFrames.isEmpty, "send(_:) must NOT record on the throw path")
    }

    func test_mockLiveTransport_finishThrowingTerminatesInboundWithError() async {
        struct FinishStubError: Error, Equatable {}
        let transport = MockLiveTransport()
        transport.finish(throwing: FinishStubError())

        var iterator = transport.inbound.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("inbound iterator must surface the finish-thrown error")
        } catch is FinishStubError {
            // expected — the stream terminated with the configured error.
        } catch {
            XCTFail("expected FinishStubError, got \(error)")
        }
    }

    // MARK: - Helpers

    /// Builds a `RealtimeSession` routed through a `FailFastURLProtocol`-
    /// backed URLSession. Lifecycle tests (1-4) never trigger a real mint
    /// — tasks are injected directly via `_testSetPreMintTask`. If a
    /// future refactor accidentally routes consume or prewarm through
    /// HTTP, the fail-fast protocol surfaces it via XCTFail. The
    /// integration test (5, commit 6) uses a sibling helper that routes
    /// through MockURLProtocol for scripted responses.
    private func makeDriver(now: @escaping @Sendable () -> Date = Date.init) -> RealtimeSession {
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
        let mint = MockMintResponse.make(wsURL: "wss://test.invalid")
        return RealtimeSession(
            testingOnlyMintResponse: mint,
            aiDispatch: aiDispatch,
            voiceTurnRepository: VoiceTurnRepository(controller: controller),
            cookingSession: cookingSession,
            now: now,
        )
    }

    /// Builds a `RealtimeSession` routed through a `MockURLProtocol`-
    /// backed URLSession. Used by the seam integration test (P1-P.5)
    /// to script the mint endpoint's HTTP response. Sibling to
    /// `makeDriver` — same constructor chain, only the URLSession
    /// differs. Set `MockURLProtocol.handler` before invoking a method
    /// that triggers the mint path; remember to reset in tearDown (the
    /// class's tearDown handles this).
    private func makeDriverWithMockURLProtocol() -> RealtimeSession {
        let config = AppConfig(
            supabase: AppConfig.Supabase(url: URL(string: "https://test.invalid")!, anonKey: "x"),
            posthog: nil, sentry: nil, revenueCat: nil,
            build: "1.0.0 (1)", osVersion: "17.5",
        )
        let sessionClient = SupabaseSessionClient(
            config: config,
            keychain: MockKeychain(),
            urlSession: MockURLProtocol.stubSession(),
            sentry: NoOpSentryReporter(),
        )
        let aiDispatch = AIDispatch(session: sessionClient, config: config)
        let mint = MockMintResponse.make(wsURL: "wss://test.invalid")
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
