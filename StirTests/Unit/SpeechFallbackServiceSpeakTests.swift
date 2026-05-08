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

    // MARK: - P1-Q.2 — timeout-fires-first

    /// Timeout path: the AVSpeechSynthesizerDelegate never fires
    /// (simulating a silently-no-oping synthesizer from a corrupt
    /// voice install or interrupted audio session — the P0-H bug
    /// this code defends against). The timeout Task wins the latch
    /// after `speakTimeoutSec` elapses, resumes the continuation,
    /// advances state `.modelSpeaking → .ready`, and `speak()`
    /// returns without hanging.
    ///
    /// Late-delegate no-op: after the timeout has resumed the
    /// continuation, firing `didFinish` on the delegate — simulating
    /// a delayed callback from the synthesizer that eventually
    /// catches up — must NOT trigger a second state advance or a
    /// second continuation resume. The latch's `tryResume` returning
    /// false is the production mechanism; this test verifies the
    /// observable consequence (currentState unchanged, no crash
    /// from double-resume).
    ///
    /// Timeout calibration: 100 ms is tight enough to keep the test
    /// fast, loose enough to avoid CI flake. The exact value doesn't
    /// matter for the invariant under test — only that the timeout
    /// Task gets scheduled and fires before any delegate event.
    func test_speak_timeoutFiresFirst_resumesViaTimeoutAndIgnoresLateDelegate() async throws {
        let mock = MockSpeechSynthesizer()
        let service = makeService(synthesizer: mock)

        // Compress the timeout from 10 s to 100 ms so the test
        // completes in sub-second time. Must be set BEFORE `speak()`
        // is called — the timeout Task captures the value
        // synchronously when `speak()` kicks off the race.
        service._testSetSpeakTimeoutSec(0.1)

        _ = service._testAdvanceState(to: .ready)
        _ = service._testAdvanceState(to: .modelSpeaking)
        XCTAssertEqual(service.currentState, .modelSpeaking, "precondition")

        // Kick off speak(). Mock's `speak()` stores the delegate +
        // yields on speakCalls, but the test never fires `didFinish`
        // — the delegate stays unresponsive, simulating the hang the
        // timeout defends against.
        let speakTask = Task { await service.speak("hello") }

        // Wait for the mock to observe the speak call — proves the
        // service reached synthesizer.speak() through the protocol
        // seam. Without this, a "delegate never set" failure could
        // masquerade as a timeout-fires-first success.
        var iterator = mock.speakCalls.makeAsyncIterator()
        let observedUtterance = await iterator.next()
        let utterance = try XCTUnwrap(
            observedUtterance,
            "service must reach synthesizer.speak() before suspending",
        )

        // Await speak() — the timeout branch resumes after ~100 ms.
        // If this hangs beyond the XCTest default timeout, the
        // timeout Task isn't firing, and the test fails loud rather
        // than silently pretending the latch contract holds.
        await speakTask.value

        // Pin (1): state advanced via the timeout path.
        XCTAssertEqual(
            service.currentState,
            .ready,
            "timeout branch must advance state .modelSpeaking → .ready",
        )

        // Pin (2): a late delegate callback is a no-op. The latch's
        // tryResume returns false, so the delegate's continuation-
        // resume and state-advance branches don't run. Observable
        // consequence: currentState stays `.ready` (not re-advanced,
        // no crash).
        let dummySynth = AVSpeechSynthesizer()
        let delegate = try XCTUnwrap(
            mock.delegate,
            "delegate should still be stored on mock — speak() only nils `synthesisDelegate`, not `synthesizer.delegate`",
        )
        delegate.speechSynthesizer?(dummySynth, didFinish: utterance)

        // Yield so the delegate's Task { @MainActor ... } closure
        // runs if it's going to (it shouldn't, per the latch). If
        // the latch is broken and the closure runs anyway, the
        // Task-hopped state advance would surface here.
        await Task.yield()
        XCTAssertEqual(
            service.currentState,
            .ready,
            "late delegate must not re-advance state (latch blocks re-entry)",
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

    /// SCA-142: tests can flip this to model "synthesis is mid-flight"
    /// for cancel-path coverage. Default false matches the
    /// constructed-but-never-used state.
    var isSpeakingOverride: Bool = false
    var isSpeaking: Bool { isSpeakingOverride }
    private(set) var stopSpeakingCalls: [AVSpeechBoundary] = []

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

    @discardableResult
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stopSpeakingCalls.append(boundary)
        let wasSpeaking = isSpeakingOverride
        // Mirror AVSpeechSynthesizer behavior: a successful stop
        // resets isSpeaking to false. Tests that want to assert the
        // pre-stop state should snapshot before calling.
        //
        // Review W3: the Bool return is "wasSpeaking" (pre-state) which
        // coincides with AVSpeechSynthesizer's "stopped speech" return
        // for the simple single-utterance case used by tests. For a
        // real synth with a queued-utterance pipeline the two
        // semantics could diverge, but production callsites all use
        // `@discardableResult` and ignore the return — so this
        // simplification is contract-safe today. Revisit if a future
        // assertion threads the return value.
        isSpeakingOverride = false
        return wasSpeaking
    }

    deinit {
        speakContinuation.finish()
    }
}
