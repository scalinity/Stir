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
        let json = frame.asJSONObject()
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
        let json = frame.asJSONObject()
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
        let json = frame.asJSONObject()
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
        let frame = try XCTUnwrap(LiveInboundFrame.parse(json))
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
        let frame = try XCTUnwrap(LiveInboundFrame.parse(json))
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
        let frame = try XCTUnwrap(LiveInboundFrame.parse(json))
        guard case let .serverContent(content) = frame else {
            XCTFail("expected .serverContent"); return
        }
        XCTAssertTrue(content.turnComplete)
        XCTAssertTrue(content.audioChunks.isEmpty)
    }

    func test_inbound_serverContent_flagsInterrupted() throws {
        let json: Any = ["serverContent": ["interrupted": true]]
        let frame = try XCTUnwrap(LiveInboundFrame.parse(json))
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
        let frame = try XCTUnwrap(LiveInboundFrame.parse(json))
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
        let frame = try XCTUnwrap(LiveInboundFrame.parse(json))
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
        let frame = try XCTUnwrap(LiveInboundFrame.parse(json))
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
        let frame = try XCTUnwrap(LiveInboundFrame.parse(json))
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
        let frame = try XCTUnwrap(LiveInboundFrame.parse(json))
        guard case let .goAway(ms) = frame else {
            XCTFail("expected .goAway"); return
        }
        XCTAssertEqual(ms, 5000)
    }

    func test_inbound_goAway_parses_when_ms_is_missing() throws {
        let json: Any = ["goAway": [:]]
        let frame = try XCTUnwrap(LiveInboundFrame.parse(json))
        guard case let .goAway(ms) = frame else {
            XCTFail("expected .goAway"); return
        }
        XCTAssertNil(ms)
    }

    // MARK: - Inbound: unknown envelope

    func test_inbound_unknown_key_returns_unknown_case() throws {
        let json: Any = ["somethingWeDontKnowAboutYet": ["foo": "bar"]]
        let frame = try XCTUnwrap(LiveInboundFrame.parse(json))
        if case let .unknown(key) = frame {
            XCTAssertEqual(key, "somethingWeDontKnowAboutYet")
        } else {
            XCTFail("expected .unknown, got \(frame)")
        }
    }

    // MARK: - Inbound: malformed shape returns nil (not crash)

    func test_inbound_malformed_shape_returns_nil() {
        XCTAssertNil(LiveInboundFrame.parse("just a string"))
        XCTAssertNil(LiveInboundFrame.parse(42))
        XCTAssertNil(LiveInboundFrame.parse([] as [Any]))
    }
}
