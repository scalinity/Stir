// VoiceSessionStateTests
//
// State-machine transition table validation. The machine is shared
// between C.3 (Speech fallback) and C.2 (Gemini Live); this suite pins
// the grammar so future C.2 additions can't silently break C.3.

import XCTest
@testable import Stir

@MainActor
final class VoiceSessionStateTests: XCTestCase {

    // MARK: - Legal subset (C.3 fallback path)

    func test_fallbackHappyPath_idleToReadyToUserSpeakingToTranscribingToThinkingToModelSpeakingToReady() {
        let machine = VoiceSessionStateMachine()
        XCTAssertEqual(machine.state, .idle)

        XCTAssertTrue(machine.advance(to: .ready))
        XCTAssertTrue(machine.advance(to: .userSpeaking))
        XCTAssertTrue(machine.advance(to: .transcribing))
        XCTAssertTrue(machine.advance(to: .thinking))
        XCTAssertTrue(machine.advance(to: .modelSpeaking))
        XCTAssertTrue(machine.advance(to: .ready), "modelSpeaking → ready is the next-turn transition")
    }

    // MARK: - Legal subset (C.2 live path additions)

    func test_livePath_idleToConnectingToReady() {
        let machine = VoiceSessionStateMachine()
        XCTAssertTrue(machine.advance(to: .connecting))
        XCTAssertTrue(machine.advance(to: .ready))
    }

    func test_livePath_userSpeakingCanSkipTranscribingAndGoDirectToThinking() {
        // C.2: Gemini Live's server VAD terminates the turn — there's
        // no client-side `.transcribing` phase.
        let machine = VoiceSessionStateMachine()
        XCTAssertTrue(machine.advance(to: .ready))
        XCTAssertTrue(machine.advance(to: .userSpeaking))
        XCTAssertTrue(machine.advance(to: .thinking))
    }

    func test_livePath_thinkingCanGoToToolCallingOrModelSpeaking() {
        let machine = VoiceSessionStateMachine()
        _ = machine.advance(to: .ready)
        _ = machine.advance(to: .userSpeaking)
        _ = machine.advance(to: .thinking)
        XCTAssertTrue(machine.advance(to: .toolCalling))
        // toolCalling resolves back to modelSpeaking.
        XCTAssertTrue(machine.advance(to: .modelSpeaking))
    }

    func test_livePath_refreshTransition() {
        let machine = VoiceSessionStateMachine()
        _ = machine.advance(to: .ready)
        _ = machine.advance(to: .userSpeaking)
        _ = machine.advance(to: .thinking)
        _ = machine.advance(to: .modelSpeaking)
        XCTAssertTrue(machine.advance(to: .refreshing))
        XCTAssertTrue(machine.advance(to: .ready))
    }

    func test_livePath_fallingBackToReady() {
        let machine = VoiceSessionStateMachine()
        _ = machine.advance(to: .connecting)
        _ = machine.advance(to: .ready)
        _ = machine.advance(to: .userSpeaking)
        _ = machine.advance(to: .thinking)
        _ = machine.advance(to: .modelSpeaking)
        _ = machine.advance(to: .refreshing)
        XCTAssertTrue(machine.advance(to: .fallingBack))
        XCTAssertTrue(machine.advance(to: .ready), "fallingBack → ready completes the fallback handoff")
    }

    // MARK: - Terminal transitions are always legal

    func test_anyState_canTransitionToError() {
        for s in VoiceSessionState.allCases where s != .error && s != .closed {
            XCTAssertTrue(s.canTransition(to: .error), "\(s) → error must be legal")
        }
    }

    func test_anyState_canTransitionToClosed() {
        for s in VoiceSessionState.allCases where s != .error && s != .closed {
            XCTAssertTrue(s.canTransition(to: .closed), "\(s) → closed must be legal")
        }
    }

    func test_terminal_cannotTransitionForward() {
        XCTAssertFalse(VoiceSessionState.error.canTransition(to: .ready))
        XCTAssertFalse(VoiceSessionState.closed.canTransition(to: .ready))
    }

    // MARK: - Hands-free (C.2) additions

    func test_livePath_handsFree_readyToModelSpeakingIsLegal() {
        // Hands-free next-turn: mic stays hot across turn boundaries,
        // so iOS state is .ready when the server finishes processing
        // the user's NEXT utterance and starts emitting audio. The
        // .ready → .modelSpeaking edge is the hands-free entry into
        // the model's response without any iOS-driven .userSpeaking
        // transition.
        XCTAssertTrue(VoiceSessionState.ready.canTransition(to: .modelSpeaking))
    }

    func test_livePath_handsFree_userSpeakingToModelSpeakingIsLegal() {
        // Hands-free fast path: server VAD fires while iOS is still in
        // .userSpeaking; the first inbound audio chunks advance state
        // directly without a .thinking pit stop.
        XCTAssertTrue(VoiceSessionState.userSpeaking.canTransition(to: .modelSpeaking))
    }

    func test_livePath_userSpeakingToReadyIsLegal() {
        // Edge: server VAD fired but model chose not to respond
        // (turnComplete with no audio). No .modelSpeaking hop needed.
        XCTAssertTrue(VoiceSessionState.userSpeaking.canTransition(to: .ready))
    }

    func test_livePath_thinkingToReadyIsLegal() {
        // Bare turnComplete after explicit tap-to-end: VM advanced to
        // .thinking, server emitted empty turnComplete. handleServer-
        // Content needs to collapse straight to .ready.
        XCTAssertTrue(VoiceSessionState.thinking.canTransition(to: .ready))
    }

    func test_livePath_fullHandsFreeLoop_readyTurn1ToReadyTurn2() {
        // Turn 1: tap-to-start.
        let machine = VoiceSessionStateMachine()
        _ = machine.advance(to: .connecting)
        _ = machine.advance(to: .ready)
        _ = machine.advance(to: .userSpeaking)
        // VAD-driven turn completion: userSpeaking → modelSpeaking
        // direct (no thinking), then → ready on turnComplete.
        XCTAssertTrue(machine.advance(to: .modelSpeaking))
        XCTAssertTrue(machine.advance(to: .ready))
        // Turn 2: user speaks again, mic still hot, no beginTurn call.
        // First server audio drives ready → modelSpeaking → ready.
        XCTAssertTrue(machine.advance(to: .modelSpeaking))
        XCTAssertTrue(machine.advance(to: .ready))
    }

    // MARK: - Illegal transitions

    func test_illegal_idleToUserSpeaking() {
        XCTAssertFalse(VoiceSessionState.idle.canTransition(to: .userSpeaking),
                       "must transition through ready first")
    }

    func test_illegal_transcribingToModelSpeaking() {
        // Must go through `thinking` first — backend response hasn't arrived.
        XCTAssertFalse(VoiceSessionState.transcribing.canTransition(to: .modelSpeaking))
    }

    func test_illegal_readyToUnrelatedLateStates() {
        // .ready can only step forward into .userSpeaking (tap-start)
        // or .modelSpeaking (hands-free next turn). Other forward
        // states (.thinking, .transcribing, .toolCalling) still
        // require traversal through intermediate steps.
        XCTAssertFalse(VoiceSessionState.ready.canTransition(to: .thinking))
        XCTAssertFalse(VoiceSessionState.ready.canTransition(to: .transcribing))
        XCTAssertFalse(VoiceSessionState.ready.canTransition(to: .toolCalling))
    }

    // MARK: - Callback

    func test_onTransitionCallback_firesWithOldAndNewState() {
        let machine = VoiceSessionStateMachine()
        var observed: [(VoiceSessionState, VoiceSessionState)] = []
        machine.onTransition = { old, new in observed.append((old, new)) }

        _ = machine.advance(to: .ready)
        _ = machine.advance(to: .userSpeaking)

        XCTAssertEqual(observed.count, 2)
        XCTAssertEqual(observed[0].0, .idle)
        XCTAssertEqual(observed[0].1, .ready)
        XCTAssertEqual(observed[1].0, .ready)
        XCTAssertEqual(observed[1].1, .userSpeaking)
    }

    // Note: advance() calls assertionFailure() on illegal transitions,
    // which crashes Debug-configuration test runners. The release-mode
    // behavior (silently drop + log) is correct production behavior;
    // to test THAT path under XCTest we'd need to stub Swift's
    // assertion handler per-test, which is not worth the complexity.
    // Instead, we pin the transition TABLE via canTransition() above —
    // the advance() implementation just routes to that table + a
    // `state = newValue` assignment, so table-correctness is sufficient.

    // MARK: - Force close

    func test_forceClose_fromAnyState() {
        let machine = VoiceSessionStateMachine()
        _ = machine.advance(to: .ready)
        _ = machine.advance(to: .userSpeaking)
        machine.forceClose()
        XCTAssertEqual(machine.state, .closed)
    }
}
