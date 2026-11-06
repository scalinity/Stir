// LiveFrames
//
// Typed frames for the Cook Mode voice WebSocket, as an adapter over the
// OpenAI Realtime protocol. The session state machine, watchdogs, tool
// dispatch and usage reporting were built around a small set of typed
// frames; this file maps OpenAI's flat `{"type": ...}` events onto them
// (inbound) and expands them into OpenAI client events (outbound), so none
// of that tested logic had to move.
//
// Wire facts pinned here so a server-side drift shows up as a type error:
//   - Every server message is ONE JSON object with a `type` field. Events
//     Stir doesn't act on parse to no frames; unknown types parse to
//     `.unknown(key: type)`.
//   - Audio is base64 PCM16 mono @ 24 kHz in both directions.
//   - Tool calls arrive as `response.function_call_arguments.done` and the
//     result goes back as a `function_call_output` conversation item. The
//     model does NOT continue on its own after a tool result, so the
//     output is always followed by an explicit `response.create`.
//   - In-session text injection is a `conversation.item.create` user
//     message followed by `response.create` (same reason).
//   - `response.done` carries usage for ONE response. A turn that calls a
//     tool has two responses (tool call, then spoken reply); only the
//     second one completes the turn.
//   - The input transcript arrives as a full utterance, asynchronously,
//     often after model audio has started.

import Foundation
import OSLog

// MARK: - Outbound frames (iOS → server)

/// Everything iOS sends after the WebSocket is open. Some frames expand to
/// more than one wire message, so the encoders return an ordered array and
/// the transport sends each in order.
enum LiveOutboundFrame {
    /// The backend pre-serialized `{"type":"session.update","session":{...}}`
    /// and sends it as `setup_frame_json`. It is forwarded verbatim as the
    /// first message so iOS can't drift from what the backend minted the
    /// client secret for, and so the 4–8 KiB payload isn't parsed and
    /// re-serialized on every preWarm and refresh. The server does not
    /// emit `session.updated` (→ `.setupComplete`) until it receives this.
    case setupRawJSON(String)
    /// `mimeType` is carried for the mic pipeline's bookkeeping; the wire
    /// message has no field for it (the session format is fixed at 24 kHz
    /// PCM16 by the setup frame).
    case realtimeInputAudio(base64: String, mimeType: String)
    case realtimeInputText(String)
    /// `name` is not on the wire — OpenAI correlates by `call_id` alone.
    case toolResponse(functionResponseId: String, name: String, response: [String: Any])
    /// Mid-session `session.update`. `payload` is the inner `session` object.
    case sessionUpdate(payload: [String: Any])

    /// Wire messages as JSON-ready dictionaries, in send order. Empty for
    /// `.setupRawJSON`, which is already a string — callers check
    /// `asJSONString()` first. `JSONSerialization` is used (vs JSONEncoder)
    /// because tool outputs and `session.update` payloads are untyped JSON.
    func asJSONObjects() -> [[String: Any]] {
        switch self {
        case .setupRawJSON:
            return []
        case let .realtimeInputAudio(base64, _):
            return [[
                "type": "input_audio_buffer.append",
                "audio": base64,
            ]]
        case let .realtimeInputText(text):
            return [
                [
                    "type": "conversation.item.create",
                    "item": [
                        "type": "message",
                        "role": "user",
                        "content": [["type": "input_text", "text": text]],
                    ],
                ],
                ["type": "response.create"],
            ]
        case let .toolResponse(id, _, response):
            return [
                [
                    "type": "conversation.item.create",
                    "item": [
                        "type": "function_call_output",
                        "call_id": id,
                        // OpenAI wants the result as a JSON *string*, not
                        // a nested object.
                        "output": Self.jsonString(response),
                    ],
                ],
                // Required: unlike the previous provider, the model does
                // not resume speaking after a tool result by itself.
                ["type": "response.create"],
            ]
        case let .sessionUpdate(payload):
            return [[
                "type": "session.update",
                "session": payload,
            ]]
        }
    }

    /// Pre-serialized JSON string if this frame is already serialized
    /// (currently only `.setupRawJSON`). Transport uses this path to
    /// skip the JSONSerialization encode/decode round-trip.
    func asJSONString() -> String? {
        if case let .setupRawJSON(json) = self {
            return json
        }
        return nil
    }

    /// Serialize a tool-response dictionary for the `output` field.
    /// `JSONSerialization.data` raises an Objective-C exception on an
    /// invalid object graph, so validity is checked first; an
    /// unencodable result degrades to a small error object the model can
    /// narrate rather than dropping the tool output (which would leave
    /// the call unanswered and the turn stuck).
    private static func jsonString(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            Logger.voice.warning("live_tool_output_not_encodable")
            return #"{"ok":false,"error":"response_not_encodable"}"#
        }
        return string
    }
}

// MARK: - Inbound frames (server → iOS)

/// Typed view of one OpenAI Realtime server event. Dispatch is by the
/// event's `type` string (manual, not Decodable): Stir reads a handful of
/// fields from a handful of events and ignores the rest, and the
/// heterogeneous `usage` / tool-argument payloads don't fit Codable well.
enum LiveInboundFrame {
    /// `session.updated` — the server accepted our setup frame.
    case setupComplete
    case serverContent(LiveServerContent)
    case toolCall(LiveToolCall)
    case usageMetadata(LiveUsageMetadata)
    /// `input_audio_buffer.speech_stopped` — server VAD decided the user
    /// finished speaking. The only anchor for time-to-first-audio: the
    /// input transcript arrives later and asynchronously, so anchoring on
    /// it would under-report TTFA.
    case userSpeechEnded
    /// An event type we don't handle (or an `error` event, keyed
    /// `error:<code>`). Logged at debug level, never fatal, so a new
    /// server event type can't tear down a session.
    case unknown(key: String)

    /// Server events that carry nothing Stir acts on. Prefix families are
    /// matched in `isIgnored`.
    private static let ignoredTypes: Set<String> = [
        "session.created",
        "response.created",
        "response.output_item.added",
        "response.output_item.done",
        "input_audio_buffer.committed",
        "input_audio_buffer.speech_started",
        "rate_limits.updated",
        "response.output_audio.done",
        "response.output_audio_transcript.done",
        "response.function_call_arguments.delta",
    ]

    private static func isIgnored(_ type: String) -> Bool {
        ignoredTypes.contains(type)
            || type.hasPrefix("response.content_part.")
            // The one `conversation.item.*` event Stir uses is handled
            // before this check.
            || type.hasPrefix("conversation.item.")
    }

    /// Parse the frames carried by one WebSocket message. OpenAI sends one
    /// event per message, but `response.done` fans out to several frames,
    /// in dispatch-dependency order:
    ///   1. `usageMetadata` — pure state update that must land before
    ///      `turnComplete` triggers `finalizeTurn()`, otherwise the turn's
    ///      usage report would fire with zero tokens.
    ///   2. `serverContent(turnComplete)` — omitted when the response
    ///      ended in a tool call: that response is not the end of the
    ///      turn, the spoken reply (a second response) is.
    /// The tool call itself arrives earlier, in its own
    /// `function_call_arguments.done` event, so `turnContainedToolCall` is
    /// already latched when the turn finally completes (ADR 0012).
    static func parseAll(_ json: Any) -> [LiveInboundFrame] {
        guard let dict = json as? [String: Any] else { return [] }
        guard let type = dict["type"] as? String else {
            return [.unknown(key: "missing_type")]
        }

        switch type {
        case "session.updated":
            return [.setupComplete]

        case "response.output_audio.delta":
            guard let delta = dict["delta"] as? String, !delta.isEmpty else { return [] }
            var content = LiveServerContent()
            content.audioChunks = [LiveAudioChunk(base64: delta, mimeType: "audio/pcm;rate=24000")]
            return [.serverContent(content)]

        case "response.output_audio_transcript.delta":
            guard let delta = dict["delta"] as? String else { return [] }
            var content = LiveServerContent()
            content.outputTranscription = LiveTranscription(text: delta, finished: false)
            return [.serverContent(content)]

        case "conversation.item.input_audio_transcription.completed":
            guard let transcript = dict["transcript"] as? String else { return [] }
            var content = LiveServerContent()
            content.inputTranscription = LiveTranscription(text: transcript, finished: true)
            return [.serverContent(content)]

        case "input_audio_buffer.speech_stopped":
            return [.userSpeechEnded]

        case "response.function_call_arguments.done":
            guard let call = LiveFunctionCall.parse(argumentsDoneEvent: dict) else {
                Logger.voice.warning("live_tool_call_event_malformed")
                return [.unknown(key: type)]
            }
            return [.toolCall(LiveToolCall(functionCalls: [call]))]

        case "response.done":
            return parseResponseDone(dict)

        case "error":
            // Log the machine-readable `type`/`code` only. `message` is
            // free text that can echo request content, so it never
            // reaches the log. An error event does not end the session.
            let err = dict["error"] as? [String: Any]
            let errType = err?["type"] as? String ?? "unknown"
            let errCode = err?["code"] as? String ?? "unknown"
            Logger.voice.warning(
                "live_ws_error_event type=\(errType, privacy: .public) code=\(errCode, privacy: .public)",
            )
            return [.unknown(key: "error:\(errCode)")]

        default:
            return isIgnored(type) ? [] : [.unknown(key: type)]
        }
    }

    private static func parseResponseDone(_ dict: [String: Any]) -> [LiveInboundFrame] {
        let response = dict["response"] as? [String: Any] ?? [:]
        var frames: [LiveInboundFrame] = []

        if let usage = response["usage"] as? [String: Any] {
            frames.append(.usageMetadata(LiveUsageMetadata.parse(usage)))
        }

        // Anything other than `completed` (failed / cancelled /
        // incomplete) still ends the turn so the state machine can't
        // wedge in `.modelSpeaking`; the status is logged for triage.
        // Status and reason are enum strings — response content is never
        // logged.
        let status = response["status"] as? String ?? "unknown"
        if status != "completed" {
            let details = response["status_details"] as? [String: Any]
            let reason = details?["reason"] as? String ?? "none"
            Logger.voice.warning(
                "live_response_not_completed status=\(status, privacy: .public) reason=\(reason, privacy: .public)",
            )
        }

        let output = response["output"] as? [[String: Any]] ?? []
        let endedInToolCall = output.contains { ($0["type"] as? String) == "function_call" }
        if !endedInToolCall {
            var content = LiveServerContent()
            content.turnComplete = true
            frames.append(.serverContent(content))
        }
        return frames
    }
}

/// Model output and user-transcript content for the current turn.
struct LiveServerContent: Sendable, Equatable {
    /// Base64 PCM16 chunks, mimeType `audio/pcm;rate=24000`.
    var audioChunks: [LiveAudioChunk] = []
    /// What the server heard the USER say. Populated from
    /// `conversation.item.input_audio_transcription.completed`, which is
    /// the FULL utterance (not a delta) and may arrive after the model has
    /// started answering. Requires input transcription in the session
    /// config; if the model doesn't seem to "hear" the user, this staying
    /// nil on a speaking user is the diagnostic.
    var inputTranscription: LiveTranscription?
    /// What the MODEL is speaking, as deltas
    /// (`response.output_audio_transcript.delta`).
    var outputTranscription: LiveTranscription?
    /// The response ended and it was not a tool-call response. The state
    /// machine advances `.modelSpeaking` back to `.ready` on this.
    var turnComplete: Bool = false
}

/// One transcription frame. `finished` is true for the full-utterance
/// input transcript and false for streamed output deltas.
struct LiveTranscription: Sendable, Equatable {
    let text: String
    let finished: Bool
}

struct LiveAudioChunk: Sendable, Equatable {
    let base64: String
    let mimeType: String
}

/// A model request for iOS to run functions. OpenAI delivers one call per
/// event, so the array has length 1 in practice; the array form is kept
/// because the dispatcher iterates it.
struct LiveToolCall: Sendable, Equatable {
    let functionCalls: [LiveFunctionCall]
}

/// `@unchecked Sendable` because `args: [String: Any]` is heterogeneous
/// (String/Int/NSNumber in practice; never mutable closures or refs).
/// The dict is `let`-immutable after parse — no races are possible.
struct LiveFunctionCall: @unchecked Sendable, Equatable {
    /// Opaque `call_id` the server expects back on the
    /// `function_call_output` item.
    let id: String
    let name: String
    /// Arguments as a heterogeneous dictionary. Stir's tool signatures
    /// only use strings/ints, so we expose both a raw dict for logging
    /// and typed accessors for the specific tools.
    let args: [String: Any]

    static func == (lhs: LiveFunctionCall, rhs: LiveFunctionCall) -> Bool {
        // Equatable ignores args (heterogeneous) — use id+name identity.
        lhs.id == rhs.id && lhs.name == rhs.name
    }

    /// Build from a `response.function_call_arguments.done` event
    /// (`call_id`, `name`, `arguments` as a JSON STRING). Malformed
    /// arguments degrade to an empty dict so the call still reaches
    /// `dispatchTool`, whose per-tool guards turn a missing argument into
    /// a structured error the model can narrate. Only the tool name is
    /// logged, never the argument text.
    static func parse(argumentsDoneEvent event: [String: Any]) -> LiveFunctionCall? {
        guard let id = event["call_id"] as? String, !id.isEmpty,
              let name = event["name"] as? String, !name.isEmpty
        else { return nil }

        var args: [String: Any] = [:]
        if let raw = event["arguments"] as? String,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let data = raw.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                args = parsed
            } else {
                Logger.voice.warning(
                    "live_tool_arguments_malformed name=\(name, privacy: .public)",
                )
            }
        }
        return LiveFunctionCall(id: id, name: name, args: args)
    }

    // MARK: - Typed args for Stir's tools

    /// `substitution_check.missing_ingredient` — required string arg.
    var substitutionMissingIngredient: String? {
        args["missing_ingredient"] as? String
    }

    /// `substitution_check.user_problem` — optional context string.
    var substitutionUserProblem: String? {
        args["user_problem"] as? String
    }

    /// `start_timer.seconds` — required int arg. Clamped to a cooking-
    /// plausible range (1 sec to 4 hours) so a malicious or malformed
    /// response can't feed `Int.max` / negative values into the timer
    /// scheduler and trigger overflow or infinite timers.
    var timerSeconds: Int? {
        // Discriminate Bool from Int by inspecting the underlying
        // CFNumberType. `NSNumber(value: 1) as? Int` succeeds (returns 1)
        // AND `NSNumber(value: 1) is Bool` ALSO succeeds (returns true,
        // because NSNumber(1) bridges to Bool(true) in Swift), so an
        // `is Bool` guard rejects real integers too. Only CFBooleanGetTypeID
        // reliably distinguishes __NSCFBoolean from __NSCFNumber
        // (review 2026-04-22: timerSeconds and targetStepNumber both
        // silently rejected integer 1 because of this).
        if let n = args["seconds"] as? NSNumber,
           CFGetTypeID(n) == CFBooleanGetTypeID() {
            return nil
        }
        let raw: Int?
        if let i = args["seconds"] as? Int { raw = i }
        else if let n = args["seconds"] as? NSNumber { raw = n.intValue }
        else if let s = args["seconds"] as? String { raw = Int(s) }
        else { raw = nil }
        guard let value = raw, (1...14400).contains(value) else { return nil }
        return value
    }

    /// `start_timer.label` — optional string arg.
    var timerLabel: String? {
        args["label"] as? String
    }

    /// `set_step.step_number` — nominally 1-indexed int arg. The model
    /// sometimes emits `step_number: 0` when the user says "step one"
    /// (model briefly mistakes the tool contract for 0-indexed — observed
    /// 2026-04-22 on a multi-turn session where every step 2..5
    /// succeeded but "step one" consistently came back ok=false). Rather
    /// than reject and force the model to spit out "that step doesn't
    /// exist", we clamp gracefully:
    ///
    ///   step_number <= 0   → treated as 1 (user wants the start)
    ///   step_number >= 101 → treated as 100 (VM clamps to totalSteps)
    ///
    /// The VM's own `jumpToStep` clamps again to `[0, totalSteps-1]`,
    /// so out-of-bounds requests still settle on a valid step. Only
    /// truly unparseable payloads (Bool, non-numeric string, missing)
    /// still return nil — those are genuine malformed calls.
    var targetStepNumber: Int? {
        // Same CFBooleanGetTypeID discriminator as `timerSeconds` — an
        // `is Bool` check would over-reject integer 1 because
        // NSNumber(value: 1) bridges to Bool(true). Observed 2026-04-22:
        // this path returned nil for step_number=1 on every "go to step
        // one" request, producing a misleading "that step doesn't exist"
        // narration.
        if let n = args["step_number"] as? NSNumber,
           CFGetTypeID(n) == CFBooleanGetTypeID() {
            return nil
        }
        let raw: Int?
        if let i = args["step_number"] as? Int { raw = i }
        else if let n = args["step_number"] as? NSNumber { raw = n.intValue }
        else if let s = args["step_number"] as? String { raw = Int(s) }
        else { raw = nil }
        guard let value = raw else { return nil }
        // Clamp rather than reject. The VM re-clamps to totalSteps, and
        // the tool response's `ok: true` lets the model narrate the
        // actually-selected step instead of gaslighting the user with
        // "that step doesn't exist."
        return min(100, max(1, value))
    }
}

/// Per-response token accounting from `response.done.response.usage`.
/// Stir uses it to drive the `voice_session_token_snapshot` telemetry and
/// the voice-turn-usage report. A tool-call turn has two responses, so the
/// session's `TurnUsageAccumulator` sums the frames.
struct LiveUsageMetadata: Sendable, Equatable {
    /// `input_tokens` — text + audio (+ image) input, INCLUDING cached.
    let promptTokenCount: Int
    /// `output_tokens` — audio + text output.
    let responseTokenCount: Int
    /// `total_tokens` for this response.
    let totalTokenCount: Int

    /// Per-modality breakdown from `input_token_details` /
    /// `output_token_details`.
    let promptAudioTokens: Int?
    let promptTextTokens: Int?
    let responseAudioTokens: Int?
    let responseTextTokens: Int?
    /// Cached TEXT input tokens (`cached_tokens_details.text_tokens`).
    /// Billed at the discounted cached rate; text and audio are cached at
    /// different rates, so they are carried separately. Cache hits are
    /// the main voice cost lever.
    let cachedContentTokenCount: Int?
    /// Cached AUDIO input tokens (`cached_tokens_details.audio_tokens`).
    let cachedAudioTokens: Int?

    static func parse(_ obj: [String: Any]) -> LiveUsageMetadata {
        let prompt = obj["input_tokens"] as? Int ?? 0
        let response = obj["output_tokens"] as? Int ?? 0
        let total = obj["total_tokens"] as? Int ?? (prompt + response)

        let inDetails = obj["input_token_details"] as? [String: Any]
        let outDetails = obj["output_token_details"] as? [String: Any]
        let cachedDetails = inDetails?["cached_tokens_details"] as? [String: Any]

        return LiveUsageMetadata(
            promptTokenCount: prompt,
            responseTokenCount: response,
            totalTokenCount: total,
            promptAudioTokens: inDetails?["audio_tokens"] as? Int,
            promptTextTokens: inDetails?["text_tokens"] as? Int,
            responseAudioTokens: outDetails?["audio_tokens"] as? Int,
            responseTextTokens: outDetails?["text_tokens"] as? Int,
            cachedContentTokenCount: cachedDetails?["text_tokens"] as? Int,
            cachedAudioTokens: cachedDetails?["audio_tokens"] as? Int,
        )
    }
}
