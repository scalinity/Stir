// LiveFramesTests
//
// Pins the wire contract for the Gemini Live Constrained WebSocket —
// every encode/decode path in LiveFrames.swift. These are the highest-
// leverage tests in C.2: if Google drifts the JSON shape, these break
// immediately instead of surfacing as mysterious runtime silence.
//
// Not covered here (by design — needs a real backend):
//   - End-to-end session lifecycle (preWarm → beginTurn → endTurn)
//   - Audio pipeline timing / sample-rate conversion correctness
//   - Tool-call → /v1/ai/substitution round trip
// Those live behind the D.1 validation gate, not a unit test.

import XCTest
@testable import Stir

final class LiveFramesTests: XCTestCase {

    // MARK: - Outbound: realtimeInput.audio

    func test_outbound_realtimeInputAudio_wraps_under_realtimeInput_audio_keys() throws {
        let frame = LiveOutboundFrame.realtimeInputAudio(
            base64: "AAECAw==",
            mimeType: "audio/pcm;rate=16000",
        )
        let json = try XCTUnwrap(frame.asJSONObject())
        let ri = try XCTUnwrap(json["realtimeInput"] as? [String: Any])
        let audio = try XCTUnwrap(ri["audio"] as? [String: Any])
        XCTAssertEqual(audio["data"] as? String, "AAECAw==")
        XCTAssertEqual(audio["mimeType"] as? String, "audio/pcm;rate=16000")
    }

    // MARK: - Outbound: realtimeInput.text (NOT clientContent)

    func test_outbound_realtimeInputText_uses_realtimeInput_not_clientContent() throws {
        // CLAUDE.md §sharp-edge #11: clientContent is history-only on
        // 3.1 Flash Live. Injected text must go via realtimeInput.text.
        let frame = LiveOutboundFrame.realtimeInputText("step advanced")
        let json = try XCTUnwrap(frame.asJSONObject())
        XCTAssertNil(json["clientContent"],
                     "in-session text MUST NOT use clientContent on 3.1 Flash Live")
        let ri = try XCTUnwrap(json["realtimeInput"] as? [String: Any])
        XCTAssertEqual(ri["text"] as? String, "step advanced")
    }

    // MARK: - Outbound: toolResponse (NOT clientContent)

    func test_outbound_toolResponse_roundTripsFunctionResponseId() throws {
        // CLAUDE.md §sharp-edge #9: function responses go via
        // toolResponse, NOT clientContent. functionResponse.id must
        // match the triggering toolCall's id exactly.
        let frame = LiveOutboundFrame.toolResponse(
            functionResponseId: "fn_abc_123",
            name: "substitution_check",
            response: ["ok": true, "text": "use olive oil"],
        )
        let json = try XCTUnwrap(frame.asJSONObject())
        XCTAssertNil(json["clientContent"],
                     "tool responses MUST NOT use clientContent")
        let tr = try XCTUnwrap(json["toolResponse"] as? [String: Any])
        let arr = try XCTUnwrap(tr["functionResponses"] as? [[String: Any]])
        XCTAssertEqual(arr.count, 1)
        XCTAssertEqual(arr.first?["id"] as? String, "fn_abc_123")
        XCTAssertEqual(arr.first?["name"] as? String, "substitution_check")
        let response = try XCTUnwrap(arr.first?["response"] as? [String: Any])
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["text"] as? String, "use olive oil")
    }

    // MARK: - Inbound: setupComplete

    func test_inbound_setupComplete_parses_to_enum_case() throws {
        let json: Any = ["setupComplete": [:]]
        let frame = try XCTUnwrap(LiveInboundFrame.parseAll(json).first)
        if case .setupComplete = frame {} else {
            XCTFail("expected .setupComplete, got \(frame)")
        }
    }

    // MARK: - Inbound: serverContent (audio + turnComplete)

    func test_inbound_serverContent_aggregates_inline_audio_chunks() throws {
        let json: Any = [
            "serverContent": [
                "modelTurn": [
                    "parts": [
                        [
                            "inlineData": [
                                "data": "BASE64AUDIO1",
                                "mimeType": "audio/pcm;rate=24000",
                            ],
                        ],
                        [
                            "inlineData": [
                                "data": "BASE64AUDIO2",
                                "mimeType": "audio/pcm;rate=24000",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let frame = try XCTUnwrap(LiveInboundFrame.parseAll(json).first)
        guard case let .serverContent(content) = frame else {
            XCTFail("expected .serverContent"); return
        }
        XCTAssertEqual(content.audioChunks.count, 2)
        XCTAssertEqual(content.audioChunks.first?.base64, "BASE64AUDIO1")
        XCTAssertEqual(content.audioChunks.last?.base64, "BASE64AUDIO2")
        XCTAssertEqual(content.audioChunks.first?.mimeType, "audio/pcm;rate=24000")
        XCTAssertFalse(content.turnComplete)
    }

    func test_inbound_serverContent_flagsTurnComplete() throws {
        let json: Any = ["serverContent": ["turnComplete": true]]
        let frame = try XCTUnwrap(LiveInboundFrame.parseAll(json).first)
        guard case let .serverContent(content) = frame else {
            XCTFail("expected .serverContent"); return
        }
        XCTAssertTrue(content.turnComplete)
        XCTAssertTrue(content.audioChunks.isEmpty)
    }

    func test_inbound_serverContent_flagsInterrupted() throws {
        let json: Any = ["serverContent": ["interrupted": true]]
        let frame = try XCTUnwrap(LiveInboundFrame.parseAll(json).first)
        guard case let .serverContent(content) = frame else {
            XCTFail("expected .serverContent"); return
        }
        XCTAssertTrue(content.interrupted)
    }

    // MARK: - Inbound: toolCall

    func test_inbound_toolCall_parses_function_calls_with_typed_args() throws {
        let json: Any = [
            "toolCall": [
                "functionCalls": [[
                    "id": "fn_sub_42",
                    "name": "substitution_check",
                    "args": [
                        "missing_ingredient": "butter",
                        "user_problem": "out of butter",
                    ],
                ]],
            ],
        ]
        let frame = try XCTUnwrap(LiveInboundFrame.parseAll(json).first)
        guard case let .toolCall(tc) = frame else {
            XCTFail("expected .toolCall"); return
        }
        XCTAssertEqual(tc.functionCalls.count, 1)
        let call = try XCTUnwrap(tc.functionCalls.first)
        XCTAssertEqual(call.id, "fn_sub_42")
        XCTAssertEqual(call.name, "substitution_check")
        XCTAssertEqual(call.substitutionMissingIngredient, "butter")
        XCTAssertEqual(call.substitutionUserProblem, "out of butter")
    }

    func test_inbound_toolCall_startTimer_parses_seconds_as_string_fallback() throws {
        // Gemini sometimes emits numeric-looking fields as strings in
        // proto-encoded JSON. LiveFunctionCall.timerSeconds must handle
        // Int + NSNumber + String without crashing.
        let json: Any = [
            "toolCall": [
                "functionCalls": [[
                    "id": "fn_timer_9",
                    "name": "start_timer",
                    "args": [
                        "seconds": "600",  // string, not int
                        "label": "simmer",
                    ],
                ]],
            ],
        ]
        let frame = try XCTUnwrap(LiveInboundFrame.parseAll(json).first)
        guard case let .toolCall(tc) = frame, let call = tc.functionCalls.first else {
            XCTFail("expected .toolCall"); return
        }
        XCTAssertEqual(call.timerSeconds, 600)
        XCTAssertEqual(call.timerLabel, "simmer")
    }

    func test_inbound_toolCall_stringifies_numeric_id() throws {
        let json: Any = [
            "toolCall": [
                "functionCalls": [[
                    "id": 42,
                    "name": "advance_step",
                    "args": [:],
                ]],
            ],
        ]
        let frame = try XCTUnwrap(LiveInboundFrame.parseAll(json).first)
        guard case let .toolCall(tc) = frame, let call = tc.functionCalls.first else {
            XCTFail("expected .toolCall"); return
        }
        XCTAssertEqual(call.id, "42", "numeric ids must round-trip as String")
    }

    // MARK: - Inbound: usageMetadata

    func test_inbound_usageMetadata_parses_per_modality_breakdown() throws {
        let json: Any = [
            "usageMetadata": [
                "promptTokenCount": 950,
                "responseTokenCount": 150,
                "totalTokenCount": 1100,
                "promptTokensDetails": [
                    ["modality": "AUDIO", "tokenCount": 825],
                    ["modality": "TEXT", "tokenCount": 125],
                ],
                "responseTokensDetails": [
                    ["modality": "AUDIO", "tokenCount": 150],
                ],
            ],
        ]
        let frame = try XCTUnwrap(LiveInboundFrame.parseAll(json).first)
        guard case let .usageMetadata(usage) = frame else {
            XCTFail("expected .usageMetadata"); return
        }
        XCTAssertEqual(usage.promptTokenCount, 950)
        XCTAssertEqual(usage.responseTokenCount, 150)
        XCTAssertEqual(usage.totalTokenCount, 1100)
        XCTAssertEqual(usage.promptAudioTokens, 825)
        XCTAssertEqual(usage.promptTextTokens, 125)
        XCTAssertEqual(usage.responseAudioTokens, 150)
        XCTAssertNil(usage.responseTextTokens)
    }

    // MARK: - Inbound: goAway

    func test_inbound_goAway_parses_disconnect_ms() throws {
        let json: Any = [
            "goAway": ["timeBeforeDisconnectMs": 5000],
        ]
        let frame = try XCTUnwrap(LiveInboundFrame.parseAll(json).first)
        guard case let .goAway(ms) = frame else {
            XCTFail("expected .goAway"); return
        }
        XCTAssertEqual(ms, 5000)
    }

    func test_inbound_goAway_parses_when_ms_is_missing() throws {
        let json: Any = ["goAway": [:]]
        let frame = try XCTUnwrap(LiveInboundFrame.parseAll(json).first)
        guard case let .goAway(ms) = frame else {
            XCTFail("expected .goAway"); return
        }
        XCTAssertNil(ms)
    }

    // MARK: - Inbound: unknown envelope

    func test_inbound_unknown_key_returns_unknown_case() throws {
        let json: Any = ["somethingWeDontKnowAboutYet": ["foo": "bar"]]
        let frame = try XCTUnwrap(LiveInboundFrame.parseAll(json).first)
        if case let .unknown(key) = frame {
            XCTAssertEqual(key, "somethingWeDontKnowAboutYet")
        } else {
            XCTFail("expected .unknown, got \(frame)")
        }
    }

    // MARK: - Inbound: malformed shape returns empty array (not crash)

    func test_inbound_malformed_shape_returns_empty_array() {
        XCTAssertTrue(LiveInboundFrame.parseAll("just a string").isEmpty)
        XCTAssertTrue(LiveInboundFrame.parseAll(42).isEmpty)
        XCTAssertTrue(LiveInboundFrame.parseAll([] as [Any]).isEmpty)
    }

    // MARK: - Inbound: multi-key envelope (the actual prod regression)

    /// Gemini Live's turnComplete envelope commonly carries BOTH
    /// `serverContent` and `usageMetadata` as siblings. An earlier
    /// `parse` version returned only the first match and dropped
    /// the usage sibling, which caused every $ai_generation to report
    /// 0 tokens in prod (observed 2026-04-22). This test pins the
    /// contract: BOTH frames must land.
    func test_inbound_envelope_with_serverContent_and_usageMetadata_yields_both() throws {
        let json: Any = [
            "serverContent": [
                "modelTurn": ["parts": [["text": "ok"]]],
                "turnComplete": true,
            ],
            "usageMetadata": [
                "promptTokenCount": 2150,
                "responseTokenCount": 150,
                "totalTokenCount": 2300,
            ],
        ]
        let frames = LiveInboundFrame.parseAll(json)
        XCTAssertEqual(frames.count, 2, "both sibling frames must be yielded")
    }

    /// Ordering invariant: `usageMetadata` MUST precede `serverContent`
    /// in the yielded array. The receive dispatcher processes frames
    /// sequentially; a `serverContent{turnComplete: true}` triggers
    /// `finalizeTurn()`, which snapshots `lastUsageMetadata`. If that
    /// snapshot runs BEFORE the usageMetadata frame lands, the voice-
    /// turn-usage POST fires with zeros. Regression class that caused
    /// 36+ zero-token events in prod 2026-04-22.
    func test_inbound_multiKey_usageMetadata_yielded_before_serverContent() throws {
        let json: Any = [
            "serverContent": [
                "modelTurn": ["parts": []],
                "turnComplete": true,
            ],
            "usageMetadata": ["promptTokenCount": 1000],
        ]
        let frames = LiveInboundFrame.parseAll(json)
        guard frames.count >= 2 else {
            XCTFail("expected at least 2 frames, got \(frames.count)"); return
        }
        if case .usageMetadata = frames[0] {} else {
            XCTFail("usageMetadata must be FIRST; got \(frames[0])")
        }
        if case .serverContent = frames[1] {} else {
            XCTFail("serverContent must be SECOND; got \(frames[1])")
        }
    }

    /// Three-key envelope: usageMetadata first (state update that must
    /// land before anything triggers finalizeTurn), toolCall second
    /// (must precede serverContent so `turnContainedToolCall` is set
    /// before `finalizeTurn()` latches it on a same-envelope turnComplete
    /// — ADR 0012 gate split), serverContent last (content + turnComplete
    /// trigger). Rare in practice but covered so the ordering doesn't
    /// silently flip if a future reorder changes parseAll.
    func test_inbound_tripleKey_envelope_usage_tool_serverContent_order() throws {
        let json: Any = [
            "usageMetadata": ["promptTokenCount": 500],
            "serverContent": ["modelTurn": ["parts": []]],
            "toolCall": [
                "functionCalls": [[
                    "id": "fn_1",
                    "name": "start_timer",
                    "args": ["seconds": 60],
                ]],
            ],
        ]
        let frames = LiveInboundFrame.parseAll(json)
        guard frames.count == 3 else {
            XCTFail("expected 3 frames, got \(frames.count)"); return
        }
        if case .usageMetadata = frames[0] {} else {
            XCTFail("frame[0] must be .usageMetadata; got \(frames[0])")
        }
        if case .toolCall = frames[1] {} else {
            XCTFail("frame[1] must be .toolCall; got \(frames[1])")
        }
        if case .serverContent = frames[2] {} else {
            XCTFail("frame[2] must be .serverContent; got \(frames[2])")
        }
    }

    /// Combined envelope {serverContent: {turnComplete: true}, toolCall}:
    /// Gemini Live's "here's my tool call AND I'm done" shape. The tool
    /// call belongs to the ENDING turn. If parseAll emitted serverContent
    /// first, `finalizeTurn()` would latch `containedToolCall = false`
    /// and then `handleToolCall` would mis-tag the NEXT turn. Reorder
    /// locked in here so the regression can't silently return.
    func test_inbound_turnComplete_with_toolCall_emits_toolCall_first() throws {
        let json: Any = [
            "serverContent": [
                "modelTurn": ["parts": []],
                "turnComplete": true,
            ],
            "toolCall": [
                "functionCalls": [[
                    "id": "fn_tc",
                    "name": "start_timer",
                    "args": ["seconds": 60],
                ]],
            ],
        ]
        let frames = LiveInboundFrame.parseAll(json)
        guard frames.count == 2 else {
            XCTFail("expected 2 frames, got \(frames.count)"); return
        }
        if case .toolCall = frames[0] {} else {
            XCTFail("toolCall must precede serverContent on combined " +
                    "turnComplete+toolCall envelope — ADR 0012 tagging; " +
                    "got \(frames[0]) first")
        }
        if case .serverContent = frames[1] {} else {
            XCTFail("frame[1] must be .serverContent; got \(frames[1])")
        }
    }
}
