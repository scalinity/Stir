import XCTest
@testable import Stir

@MainActor
final class MicCaptureGateTests: XCTestCase {
    func test_tenSecondMuteDropsCaptureAndInvalidatesBufferedAudio() async {
        let gate = MicCaptureGate()
        let pair = AsyncStream.makeStream(of: UInt64.self,
            bufferingPolicy: .bufferingNewest(LiveAudioPipeline.micBufferLimit))
        let beforeMute = gate.captureToken(at: 1)!
        pair.continuation.yield(beforeMute)
        gate.setMuted(true)
        var capturedDuringMute = 0
        for frame in 0..<500 {
            if let token = gate.captureToken(at: 2 + Double(frame) * 0.02) {
                capturedDuringMute += 1
                pair.continuation.yield(token)
            }
        }
        gate.setMuted(false)
        XCTAssertEqual(capturedDuringMute, 0)
        let current = gate.captureToken(at: 12)!
        pair.continuation.yield(current)
        pair.continuation.finish()
        var accepted: [UInt64] = []
        for await token in pair.stream where gate.accepts(token, at: 12) { accepted.append(token) }
        XCTAssertEqual(accepted, [current])
    }

    func test_suspendedConsumerRetainsOnlyRecentBoundedWindow() async {
        let gate = MicCaptureGate()
        let pair = AsyncStream.makeStream(of: Int.self,
            bufferingPolicy: .bufferingNewest(LiveAudioPipeline.micBufferLimit))
        // No consumer can drain while a WebSocket send is suspended.
        for frame in 0..<500 { pair.continuation.yield(frame) }
        pair.continuation.finish()
        var buffered: [Int] = []
        for await frame in pair.stream { buffered.append(frame) }
        XCTAssertEqual(buffered, Array(495..<500))
        let tokenBeforePlayback = gate.captureToken(at: 1)!
        gate.playbackStarted()
        gate.playbackEnded(at: 11)
        XCTAssertNil(gate.captureToken(at: 11.2), "room echo cooldown is capture-time gated")
        XCTAssertNotNil(gate.captureToken(at: 12))
        XCTAssertFalse(gate.accepts(tokenBeforePlayback, at: 12))
    }
}
