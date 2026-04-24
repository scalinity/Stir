// SpeechFallbackServiceSpeakTests
//
// P1-Q test suite. Pins the latch + timeout behavior of
// `SpeechFallbackService.speak(_:)` — the AVSpeechSynthesizer-backed
// utterance path that can silently hang when the synthesizer no-ops
// on a corrupt voice install or weird audio-session state (P0-H).
// See CLAUDE.md §Deferred "Voice-path test coverage expansion" for
// the P1-Q rationale.
//
// Tests use a `MockSpeechSynthesizer` injected through the P1-Q
// `SpeechSynthesizing` protocol seam. The mock exposes an AsyncStream
// that fires every time `speak(_:)` is called, so tests can await
// "speak was reached" deterministically — no box-and-yield-loop race.
// Same pattern as P1-P commit 5 (in-flight-await).
//
// State-machine preconditions: production reaches `speak()` with
// state `.modelSpeaking` (set by `endTurn`'s await chain). Tests
// drive state via `_testAdvanceState(to:)` through the legal
// `.idle → .ready → .modelSpeaking` sequence to match that
// precondition before calling `speak()`.

import AVFoundation
import CoreData
import XCTest
@testable import Stir

@MainActor
final class SpeechFallbackServiceSpeakTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var recipePlan: RecipePlan!
    private var cookingSession: CookingSession!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        household = try HouseholdProfileRepository(controller: controller)
            .ensureHouseholdProfile(for: "install:speak-\(UUID().uuidString)")
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

    // MARK: - P1-Q.1 — delegate-fires-first

    /// Happy path: the AVSpeechSynthesizerDelegate fires `didFinish`
    /// before the timeout elapses. Latch lets the delegate win;
    /// `speak()`'s continuation resumes; the state machine advances
    /// `.modelSpeaking → .ready`.
    ///
    /// No race on "speak was called" — the mock's AsyncStream yields
    /// on every `speak(_:)` invocation, and the test awaits `next()`
    /// before firing the delegate. If production ever starts routing
    /// speak through a different code path (bypassing the injected
    /// synthesizer), the stream's iterator returns nil and the test
    /// fails deterministically instead of timing out.
    func test_speak_delegateFiresFirst_resumesContinuationAndAdvancesState() async throws {
        let mock = MockSpeechSynthesizer()
        let service = makeService(synthesizer: mock)

        // Production calls `speak()` from `.modelSpeaking`; drive the
        // state machine through the legal `.idle → .ready →
        // .modelSpeaking` sequence to match that precondition.
        _ = service._testAdvanceState(to: .ready)
        _ = service._testAdvanceState(to: .modelSpeaking)
        XCTAssertEqual(service.currentState, .modelSpeaking, "precondition")

        // Kick off speak() — will suspend on the continuation until
        // either the delegate fires or the timeout elapses.
        let speakTask = Task { await service.speak("hello") }

        // Wait for the mock to observe the call — deterministic, no
        // yield-loop race. AsyncStream buffers the yield so ordering
        // of "task starts" vs "iterator awaits" is irrelevant.
        // `XCTUnwrap`'s autoclosure is non-async; await first, then
        // unwrap.
        var iterator = mock.speakCalls.makeAsyncIterator()
        let observedUtterance = await iterator.next()
        let utterance = try XCTUnwrap(
            observedUtterance,
            "service must call synthesizer.speak() synchronously via the protocol seam",
        )
        XCTAssertEqual(
            utterance.speechString,
            "hello",
            "utterance text must flow through unchanged",
        )

        // Fire the delegate's `didFinish`. The first argument's
        // concrete AVSpeechSynthesizer is a dummy — the service's
        // delegate callback doesn't inspect it, just uses the
        // invocation as a completion signal.
        let dummySynth = AVSpeechSynthesizer()
        let delegate = try XCTUnwrap(
            mock.delegate,
            "service must store the delegate on the injected synthesizer",
        )
        delegate.speechSynthesizer?(dummySynth, didFinish: utterance)

        // Await speak() completion — continuation resumes via the
        // delegate branch (latch lets it win; timeout path will later
        // see latch closed and no-op).
        await speakTask.value

        // State machine advanced `.modelSpeaking → .ready` per the
        // continuation-branch's `if state == .modelSpeaking` guard.
        XCTAssertEqual(
            service.currentState,
            .ready,
            "speak() must advance state machine to .ready after delegate fires",
        )
    }

    // MARK: - Helpers

    private func makeService(synthesizer: any SpeechSynthesizing) -> SpeechFallbackService {
        let config = AppConfig(
            supabase: AppConfig.Supabase(url: URL(string: "https://test.invalid")!, anonKey: "x"),
            posthog: nil, sentry: nil, revenueCat: nil,
            build: "1.0.0 (1)", osVersion: "17.5",
        )
        let sessionClient = SupabaseSessionClient(
            config: config,
            keychain: MockKeychain(),
            urlSession: .shared,
            sentry: NoOpSentryReporter(),
        )
        let aiDispatch = AIDispatch(session: sessionClient, config: config)
        return SpeechFallbackService(
            aiDispatch: aiDispatch,
            voiceTurnRepository: VoiceTurnRepository(controller: controller),
            cookingSession: cookingSession,
            synthesizer: synthesizer,
        )
    }
}

// MARK: - Mock

/// `SpeechSynthesizing` mock for P1-Q tests. Exposes an AsyncStream of
/// `speak(_:)` invocations so tests can await "speak was called"
/// deterministically instead of racing on a `Task.yield()` loop.
/// File-private to `SpeechFallbackServiceSpeakTests` — promote to a
/// shared test utility if P1-N / P1-O / a cancel-path test needs the
/// same mock.
@MainActor
private final class MockSpeechSynthesizer: SpeechSynthesizing {
    var delegate: AVSpeechSynthesizerDelegate?
    private(set) var lastUtterance: AVSpeechUtterance?

    let speakCalls: AsyncStream<AVSpeechUtterance>
    private let speakContinuation: AsyncStream<AVSpeechUtterance>.Continuation

    init() {
        var cont: AsyncStream<AVSpeechUtterance>.Continuation!
        self.speakCalls = AsyncStream { continuation in cont = continuation }
        self.speakContinuation = cont
    }

    func speak(_ utterance: AVSpeechUtterance) {
        self.lastUtterance = utterance
        self.speakContinuation.yield(utterance)
    }

    deinit {
        speakContinuation.finish()
    }
}
