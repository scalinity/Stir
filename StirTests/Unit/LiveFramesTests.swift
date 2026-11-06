// LiveFramesTests
//
// Pins the wire contract for the OpenAI Realtime WebSocket — every
// encode/decode path in LiveFrames.swift. These are the highest-leverage
// tests in the voice path: if the provider drifts an event shape, these
// break immediately instead of surfacing as mysterious runtime silence.
//
// Fixtures are literal event JSON parsed with JSONSerialization, the same
// way the transport parses real messages, so number bridging (NSNumber
// vs Int) behaves like production.
//
// Not covered here (by design — needs a real backend):
//   - End-to-end session lifecycle (preWarm → beginTurn → endTurn)
//   - Audio pipeline timing / sample-rate conversion correctness
//   - Tool-call → /v1/ai/substitution round trip
// Those live behind the D.1 validation gate, not a unit test.

import XCTest
@testable import Stir

final class LiveFramesTests: XCTestCase {

    // MARK: - Fixtures

    /// Parse a literal JSON event the way the transport does.
    private func event(_ json: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(json.utf8), options: [])
    }

    private func frames(_ json: String) throws -> [LiveInboundFrame] {
        LiveInboundFrame.parseAll(try event(json))
    }

    // MARK: - Outbound: setup frame

    func test_outbound_setupRawJSON_is_forwarded_verbatim() {
        let raw = #"{"type":"session.update","session":{"output_modalities":["audio"]}}"#
        let frame = LiveOutboundFrame.setupRawJSON(raw)
        XCTAssertEqual(frame.asJSONString(), raw, "setup frame must be sent byte-for-byte")
        XCTAssertTrue(frame.asJSONObjects().isEmpty, "raw frame has no object form to re-serialize")
    }

    // MARK: - Outbound: input_audio_buffer.append

    func test_outbound_realtimeInputAudio_is_input_audio_buffer_append() throws {
        let frame = LiveOutboundFrame.realtimeInputAudio(
            base64: "AAECAw==",
            mimeType: "audio/pcm;rate=24000",
        )
        let messages = frame.asJSONObjects()
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(messages[0]["audio"] as? String, "AAECAw==")
        XCTAssertNil(frame.asJSONString())
    }

    // MARK: - Outbound: text injection = user item + response.create

    func test_outbound_realtimeInputText_creates_user_item_then_response() throws {
        let frame = LiveOutboundFrame.realtimeInputText("step advanced")
        let messages = frame.asJSONObjects()
        XCTAssertEqual(messages.count, 2, "text injection is two messages, in order")

        XCTAssertEqual(messages[0]["type"] as? String, "conversation.item.create")
        let item = try XCTUnwrap(messages[0]["item"] as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "message")
        XCTAssertEqual(item["role"] as? String, "user")
        let content = try XCTUnwrap(item["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        XCTAssertEqual(content[0]["text"] as? String, "step advanced")

        XCTAssertEqual(messages[1]["type"] as? String, "response.create",
                       "an injected item doesn't get a reply until a response is requested")
    }

    // MARK: - Outbound: tool output = function_call_output + response.create

    func test_outbound_toolResponse_is_two_messages_with_json_string_output() throws {
        let frame = LiveOutboundFrame.toolResponse(
            functionResponseId: "call_abc_123",
            name: "substitution_check",
            response: ["ok": true, "text": "use olive oil"],
        )
        let messages = frame.asJSONObjects()
        XCTAssertEqual(messages.count, 2, "tool output is followed by an explicit response.create")

        XCTAssertEqual(messages[0]["type"] as? String, "conversation.item.create")
        let item = try XCTUnwrap(messages[0]["item"] as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "function_call_output")
        XCTAssertEqual(item["call_id"] as? String, "call_abc_123",
                       "call_id must round-trip the triggering call's id exactly")

        // `output` must be a JSON *string*, not a nested object.
        let output = try XCTUnwrap(item["output"] as? String, "output must be a string")
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
        )
        XCTAssertEqual(decoded["ok"] as? Bool, true)
        XCTAssertEqual(decoded["text"] as? String, "use olive oil")

        XCTAssertEqual(messages[1]["type"] as? String, "response.create",
                       "the model does not continue after a tool result on its own")
    }

    func test_outbound_toolResponse_unencodable_result_degrades_to_error_output() throws {
        // A Date is not valid JSON. JSONSerialization would raise an
        // Objective-C exception on it, so the encoder must degrade rather
        // than crash or leave the call unanswered.
        let frame = LiveOutboundFrame.toolResponse(
            functionResponseId: "call_bad",
            name: "start_timer",
            response: ["when": Date()],
        )
        let messages = frame.asJSONObjects()
        XCTAssertEqual(messages.count, 2)
        let item = try XCTUnwrap(messages[0]["item"] as? [String: Any])
        let output = try XCTUnwrap(item["output"] as? String)
        XCTAssertTrue(output.contains("response_not_encodable"))
    }

    // MARK: - Outbound: session.update

    func test_outbound_sessionUpdate_wraps_payload_under_session() throws {
        let frame = LiveOutboundFrame.sessionUpdate(payload: ["instructions": "be brief"])
        let messages = frame.asJSONObjects()
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["type"] as? String, "session.update")
        let session = try XCTUnwrap(messages[0]["session"] as? [String: Any])
        XCTAssertEqual(session["instructions"] as? String, "be brief")
    }

    // MARK: - Inbound: handshake

    func test_inbound_session_created_yields_no_frames() throws {
        // `session.created` arrives BEFORE our setup frame is sent. It
        // must not parse to anything (least of all .setupComplete), or
        // the handshake would resolve before the server accepted config.
        let parsed = try frames(#"{"type":"session.created","session":{"id":"sess_1"}}"#)
        XCTAssertTrue(parsed.isEmpty)
    }

    func test_inbound_session_updated_parses_to_setupComplete() throws {
        let frame = try XCTUnwrap(try frames(#"{"type":"session.updated","session":{}}"#).first)
        if case .setupComplete = frame {} else {
            XCTFail("expected .setupComplete, got \(frame)")
        }
    }

    // MARK: - Inbound: audio + transcripts

    func test_inbound_output_audio_delta_becomes_audio_chunk() throws {
        let parsed = try frames(#"{"type":"response.output_audio.delta","delta":"BASE64AUDIO1","item_id":"i"}"#)
        XCTAssertEqual(parsed.count, 1)
        guard case let .serverContent(content) = parsed[0] else {
            XCTFail("expected .serverContent"); return
        }
        XCTAssertEqual(content.audioChunks.count, 1)
        XCTAssertEqual(content.audioChunks.first?.base64, "BASE64AUDIO1")
        XCTAssertEqual(content.audioChunks.first?.mimeType, "audio/pcm;rate=24000")
        XCTAssertFalse(content.turnComplete)
    }

    func test_inbound_output_audio_transcript_delta_becomes_output_transcription() throws {
        let parsed = try frames(#"{"type":"response.output_audio_transcript.delta","delta":"Two minutes"}"#)
        guard case let .serverContent(content) = try XCTUnwrap(parsed.first) else {
            XCTFail("expected .serverContent"); return
        }
        XCTAssertEqual(content.outputTranscription?.text, "Two minutes")
        XCTAssertNil(content.inputTranscription)
        XCTAssertTrue(content.audioChunks.isEmpty)
    }

    func test_inbound_input_transcription_completed_carries_full_utterance() throws {
        let parsed = try frames(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i","transcript":"how long do I sear it"}"#,
        )
        guard case let .serverContent(content) = try XCTUnwrap(parsed.first) else {
            XCTFail("expected .serverContent"); return
        }
        XCTAssertEqual(content.inputTranscription?.text, "how long do I sear it")
        XCTAssertEqual(content.inputTranscription?.finished, true)
    }

    // MARK: - Inbound: speech_stopped (TTFA anchor)

    func test_inbound_speech_stopped_parses_to_userSpeechEnded() throws {
        let frame = try XCTUnwrap(
            try frames(#"{"type":"input_audio_buffer.speech_stopped","audio_end_ms":1200,"item_id":"i"}"#).first,
        )
        if case .userSpeechEnded = frame {} else {
            XCTFail("expected .userSpeechEnded, got \(frame)")
        }
    }

    // MARK: - Inbound: events Stir doesn't act on

    func test_inbound_ignored_events_yield_no_frames() throws {
        let ignored = [
            "response.created",
            "response.output_item.added",
            "response.output_item.done",
            "response.content_part.added",
            "response.content_part.done",
            "conversation.item.added",
            "conversation.item.done",
            "conversation.item.created",
            "conversation.item.input_audio_transcription.delta",
            "input_audio_buffer.committed",
            "input_audio_buffer.speech_started",
            "rate_limits.updated",
            "response.output_audio.done",
            "response.output_audio_transcript.done",
            "response.function_call_arguments.delta",
            "session.created",
        ]
        for type in ignored {
            let parsed = try frames(#"{"type":"\#(type)"}"#)
            XCTAssertTrue(parsed.isEmpty, "\(type) must parse to no frames, got \(parsed)")
        }
    }

    // MARK: - Inbound: function call

    func test_inbound_function_call_arguments_done_parses_to_typed_call() throws {
        let parsed = try frames("""
        {"type":"response.function_call_arguments.done","call_id":"call_sub_42",
         "name":"substitution_check","item_id":"i","output_index":0,
         "arguments":"{\\"missing_ingredient\\":\\"butter\\",\\"user_problem\\":\\"out of butter\\"}"}
        """)
        XCTAssertEqual(parsed.count, 1)
        guard case let .toolCall(tc) = parsed[0] else {
            XCTFail("expected .toolCall"); return
        }
        XCTAssertEqual(tc.functionCalls.count, 1)
        let call = try XCTUnwrap(tc.functionCalls.first)
        XCTAssertEqual(call.id, "call_sub_42")
        XCTAssertEqual(call.name, "substitution_check")
        XCTAssertEqual(call.substitutionMissingIngredient, "butter")
        XCTAssertEqual(call.substitutionUserProblem, "out of butter")
    }

    func test_inbound_function_call_integer_and_string_seconds_both_parse() throws {
        // The typed accessors must keep handling Int and String-encoded
        // numbers; models occasionally emit either.
        let asInt = try frames("""
        {"type":"response.function_call_arguments.done","call_id":"c1","name":"start_timer",
         "arguments":"{\\"seconds\\":600,\\"label\\":\\"simmer\\"}"}
        """)
        let asString = try frames("""
        {"type":"response.function_call_arguments.done","call_id":"c2","name":"start_timer",
         "arguments":"{\\"seconds\\":\\"600\\"}"}
        """)
        guard case let .toolCall(a) = try XCTUnwrap(asInt.first),
              case let .toolCall(b) = try XCTUnwrap(asString.first)
        else { XCTFail("expected .toolCall"); return }
        XCTAssertEqual(a.functionCalls.first?.timerSeconds, 600)
        XCTAssertEqual(a.functionCalls.first?.timerLabel, "simmer")
        XCTAssertEqual(b.functionCalls.first?.timerSeconds, 600)
    }

    func test_inbound_function_call_malformed_arguments_degrade_to_empty_args() throws {
        let parsed = try frames("""
        {"type":"response.function_call_arguments.done","call_id":"c3","name":"set_step",
         "arguments":"{not json"}
        """)
        guard case let .toolCall(tc) = try XCTUnwrap(parsed.first) else {
            XCTFail("expected .toolCall — a bad arguments string must not drop the call"); return
        }
        let call = try XCTUnwrap(tc.functionCalls.first)
        XCTAssertEqual(call.id, "c3")
        XCTAssertEqual(call.name, "set_step")
        XCTAssertTrue(call.args.isEmpty)
        XCTAssertNil(call.targetStepNumber)
    }

    func test_inbound_function_call_empty_arguments_are_empty_args() throws {
        let parsed = try frames("""
        {"type":"response.function_call_arguments.done","call_id":"c4","name":"get_timer_status","arguments":""}
        """)
        guard case let .toolCall(tc) = try XCTUnwrap(parsed.first) else {
            XCTFail("expected .toolCall"); return
        }
        XCTAssertTrue(try XCTUnwrap(tc.functionCalls.first).args.isEmpty)
    }

    func test_inbound_function_call_missing_call_id_is_unknown_not_crash() throws {
        let parsed = try frames(#"{"type":"response.function_call_arguments.done","name":"set_step","arguments":"{}"}"#)
        guard case .unknown = try XCTUnwrap(parsed.first) else {
            XCTFail("a call without call_id can't be answered; expected .unknown"); return
        }
    }

    // MARK: - Inbound: response.done

    private let usageJSON = """
    "usage":{"total_tokens":950,"input_tokens":800,"output_tokens":150,
      "input_token_details":{"text_tokens":300,"audio_tokens":500,"image_tokens":0,
        "cached_tokens":200,
        "cached_tokens_details":{"text_tokens":120,"audio_tokens":80}},
      "output_token_details":{"text_tokens":20,"audio_tokens":130}}
    """

    func test_inbound_response_done_emits_usage_then_turnComplete() throws {
        let parsed = try frames("""
        {"type":"response.done","response":{"id":"r","status":"completed",
         "output":[{"type":"message","role":"assistant"}],\(usageJSON)}}
        """)
        XCTAssertEqual(parsed.count, 2)
        // Order matters: usage must land before turnComplete triggers
        // finalizeTurn(), or the turn's report fires with zero tokens.
        guard case let .usageMetadata(usage) = parsed[0] else {
            XCTFail("usageMetadata must be FIRST; got \(parsed[0])"); return
        }
        XCTAssertEqual(usage.promptTokenCount, 800)
        guard case let .serverContent(content) = parsed[1] else {
            XCTFail("serverContent must be SECOND; got \(parsed[1])"); return
        }
        XCTAssertTrue(content.turnComplete)
    }

    func test_inbound_response_done_with_function_call_item_has_usage_but_no_turnComplete() throws {
        // A response that ended in a tool call is not the end of the
        // turn: the spoken reply (a second response) is.
        let parsed = try frames("""
        {"type":"response.done","response":{"id":"r","status":"completed",
         "output":[{"type":"message","role":"assistant"},
                   {"type":"function_call","name":"start_timer","call_id":"c1","arguments":"{}"}],
         \(usageJSON)}}
        """)
        XCTAssertEqual(parsed.count, 1, "usage only")
        guard case .usageMetadata = parsed[0] else {
            XCTFail("expected .usageMetadata, got \(parsed[0])"); return
        }
        for frame in parsed {
            if case let .serverContent(content) = frame {
                XCTAssertFalse(content.turnComplete, "tool-call response must not complete the turn")
            }
        }
    }

    func test_inbound_response_done_non_completed_statuses_still_complete_the_turn() throws {
        for status in ["failed", "cancelled", "incomplete"] {
            let parsed = try frames("""
            {"type":"response.done","response":{"id":"r","status":"\(status)","output":[]}}
            """)
            XCTAssertEqual(parsed.count, 1, "\(status): no usage here, only turnComplete")
            guard case let .serverContent(content) = parsed[0] else {
                XCTFail("\(status): expected .serverContent"); continue
            }
            XCTAssertTrue(content.turnComplete,
                          "\(status) must still end the turn or the state machine wedges in .modelSpeaking")
        }
    }

    func test_inbound_response_done_without_usage_yields_only_turnComplete() throws {
        let parsed = try frames(#"{"type":"response.done","response":{"status":"completed","output":[]}}"#)
        XCTAssertEqual(parsed.count, 1)
        guard case let .serverContent(content) = parsed[0] else {
            XCTFail("expected .serverContent"); return
        }
        XCTAssertTrue(content.turnComplete)
    }

    // MARK: - Inbound: usage parsing

    func test_inbound_usage_parses_modalities_and_splits_cached_text_from_audio() throws {
        let parsed = try frames("""
        {"type":"response.done","response":{"status":"completed","output":[],\(usageJSON)}}
        """)
        guard case let .usageMetadata(usage) = parsed[0] else {
            XCTFail("expected .usageMetadata"); return
        }
        XCTAssertEqual(usage.promptTokenCount, 800)
        XCTAssertEqual(usage.responseTokenCount, 150)
        XCTAssertEqual(usage.totalTokenCount, 950)
        XCTAssertEqual(usage.promptTextTokens, 300)
        XCTAssertEqual(usage.promptAudioTokens, 500)
        XCTAssertEqual(usage.responseTextTokens, 20)
        XCTAssertEqual(usage.responseAudioTokens, 130)
        XCTAssertEqual(usage.cachedContentTokenCount, 120, "cached TEXT tokens")
        XCTAssertEqual(usage.cachedAudioTokens, 80, "cached AUDIO tokens, kept separate")
    }

    func test_inbound_usage_without_details_leaves_breakdown_nil() throws {
        let parsed = try frames("""
        {"type":"response.done","response":{"status":"completed","output":[],
         "usage":{"total_tokens":110,"input_tokens":100,"output_tokens":10}}}
        """)
        guard case let .usageMetadata(usage) = parsed[0] else {
            XCTFail("expected .usageMetadata"); return
        }
        XCTAssertEqual(usage.promptTokenCount, 100)
        XCTAssertEqual(usage.responseTokenCount, 10)
        XCTAssertNil(usage.promptAudioTokens)
        XCTAssertNil(usage.responseTextTokens)
        XCTAssertNil(usage.cachedContentTokenCount)
        XCTAssertNil(usage.cachedAudioTokens)
    }

    // MARK: - Inbound: error / unknown / malformed

    func test_inbound_error_event_is_typed_without_message() throws {
        let parsed = try frames("""
        {"type":"error","event_id":"e","error":{"type":"invalid_request_error",
         "code":"conversation_already_has_active_response",
         "message":"Conversation already has an active response in progress: resp_123."}}
        """)
        XCTAssertEqual(parsed.count, 1)
        guard case let .responseError(code) = parsed[0] else {
            XCTFail("expected .responseError, got \(parsed[0])"); return
        }
        XCTAssertEqual(code, "conversation_already_has_active_response")
    }

    func test_inbound_error_event_without_code_preserves_typed_error() throws {
        let parsed = try frames(#"{"type":"error","error":{"type":"server_error","message":"boom"}}"#)
        guard case let .responseError(code) = try XCTUnwrap(parsed.first) else {
            XCTFail("expected .responseError"); return
        }
        XCTAssertEqual(code, "unknown")
    }

    func test_inbound_unknown_type_returns_unknown_case() throws {
        let parsed = try frames(#"{"type":"some.future.event","foo":"bar"}"#)
        guard case let .unknown(key) = try XCTUnwrap(parsed.first) else {
            XCTFail("expected .unknown"); return
        }
        XCTAssertEqual(key, "some.future.event")
    }

    func test_inbound_object_without_type_returns_unknown_case() throws {
        let parsed = try frames(#"{"foo":"bar"}"#)
        guard case let .unknown(key) = try XCTUnwrap(parsed.first) else {
            XCTFail("expected .unknown"); return
        }
        XCTAssertEqual(key, "missing_type")
    }

    func test_inbound_malformed_shape_returns_empty_array() {
        XCTAssertTrue(LiveInboundFrame.parseAll("just a string").isEmpty)
        XCTAssertTrue(LiveInboundFrame.parseAll(42).isEmpty)
        XCTAssertTrue(LiveInboundFrame.parseAll([] as [Any]).isEmpty)
    }
}

/// The transport's response gate: Realtime rejects `response.create` while
/// a response is active, so a tool result that's ready before the
/// requesting response's `response.done` must wait for it.
final class ResponseGateTests: XCTestCase {
    func test_createSendsImmediately_whenNoResponseActive() {
        var gate = ResponseGate()
        XCTAssertTrue(gate.requestCreate())
        XCTAssertFalse(gate.pending)
    }

    func test_toolResultBeforeResponseDone_defersCreateUntilDone() {
        // VAD-started response that ends in a function call.
        var gate = ResponseGate()
        XCTAssertFalse(gate.observe(eventType: "response.created", errorCode: nil))
        // Local tool finished before response.done arrived.
        XCTAssertFalse(gate.requestCreate(), "create must wait for the active response")
        XCTAssertTrue(gate.pending)
        // response.done releases exactly one deferred create.
        XCTAssertTrue(gate.observe(eventType: "response.done", errorCode: nil))
        XCTAssertFalse(gate.pending)
        XCTAssertTrue(gate.unacknowledged)
        // A second response.done (before the new one is created) sends nothing more.
        XCTAssertFalse(gate.observe(eventType: "response.done", errorCode: nil))
    }

    func test_createIsDeferred_untilPreviousCreateIsAcknowledged() {
        var gate = ResponseGate()
        XCTAssertTrue(gate.requestCreate())
        // Text injection right behind it, before response.created arrives.
        XCTAssertFalse(gate.requestCreate())
        XCTAssertFalse(gate.observe(eventType: "response.created", errorCode: nil))
        XCTAssertTrue(gate.observe(eventType: "response.done", errorCode: nil))
    }

    func test_activeResponseError_requeuesForNextResponseDone() {
        var gate = ResponseGate()
        XCTAssertTrue(gate.requestCreate())
        XCTAssertFalse(gate.observe(eventType: "error", errorCode: "conversation_already_has_active_response"))
        XCTAssertTrue(gate.pending)
        XCTAssertTrue(gate.observe(eventType: "response.done", errorCode: nil))
    }

    func test_otherErrors_clearAcknowledgementWait() {
        var gate = ResponseGate()
        XCTAssertTrue(gate.requestCreate())
        XCTAssertFalse(gate.observe(eventType: "error", errorCode: "invalid_value"))
        // Not wedged: the next create goes straight out.
        XCTAssertTrue(gate.requestCreate())
    }
}
