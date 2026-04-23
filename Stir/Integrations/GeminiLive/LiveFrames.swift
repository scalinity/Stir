// LiveFrames
//
// Codable wire types for the Gemini Live BidiGenerateContentConstrained
// WebSocket. This is the iOS side of what the backend mint baked in — we
// don't send a setup frame (the ephemeral token already carried it) but
// we do need to decode `serverContent`, `toolCall`, `usageMetadata`, and
// the `setupComplete` handshake, and encode `realtimeInput.audio`,
// `realtimeInput.text`, `toolResponse`, and `sessionUpdate`.
//
// Wire facts pinned here so a server-side drift shows up as a type error:
//   - JSON keys are camelCase (documented 2026-04-19 via SDK probe)
//   - Audio is base64 PCM16 @ 16 kHz for input; base64 PCM16 @ 24 kHz for
//     output per Gemini docs (CLAUDE.md §sharp-edge #10 — input rate)
//   - `functionResponse.id` on a toolResponse frame MUST match the id on
//     the triggering toolCall.functionCall — ids are opaque strings
//     (sometimes numeric-looking but always string). Round-trip as-is.
//   - In-session text injection uses `realtimeInput.text`, NOT
//     `clientContent` (CLAUDE.md §sharp-edge #11). `clientContent` is
//     history-only on 3.1 Flash Live and Stir doesn't seed history.
//   - Function responses go in `toolResponse`, NOT `clientContent`.
//     (CLAUDE.md §sharp-edge #9)

import Foundation
import OSLog

// MARK: - Outbound frames (iOS → server)

/// Envelope union for everything iOS sends after the WebSocket is open.
/// The sdk prefers oneOf-style top-level keys — we encode as a plain
/// dictionary from the struct variant to keep the wire shape exact.
enum LiveOutboundFrame {
    /// First frame iOS sends after `ws.open`. Payload is the entire
    /// `{"setup": {...}}` object as the backend pre-serialized it —
    /// forwarded verbatim so iOS doesn't risk camelCase/snake_case
    /// drift against Gemini's wire shape. Server does NOT emit
    /// `setupComplete` until it receives this frame even with a
    /// Constrained ephemeral token.
    case setup(payload: [String: Any])
    case realtimeInputAudio(base64: String, mimeType: String)
    case realtimeInputText(String)
    case toolResponse(functionResponseId: String, name: String, response: [String: Any])
    /// `session.update` — used for pruning context via turn-coverage flips
    /// and to bump generation_config mid-session when needed (CLAUDE.md
    /// #7 — pruning to last 3 turns after every step advance).
    case sessionUpdate(payload: [String: Any])

    /// Encoded as JSON-ready dictionary. `JSONSerialization` is used (vs
    /// JSONEncoder) because `toolResponse.response` and `sessionUpdate`
    /// carry untyped JSON objects — Codable would require `AnyEncodable`
    /// machinery for what's fundamentally a heterogeneous payload.
    func asJSONObject() -> [String: Any] {
        switch self {
        case let .setup(payload):
            // Payload is already shaped `{"setup": {...}}` on the
            // wire; return as-is. Backend serialized it atomically so
            // iOS never reaches into the inner shape.
            return payload
        case let .realtimeInputAudio(base64, mimeType):
            return [
                "realtimeInput": [
                    "audio": [
                        "data": base64,
                        "mimeType": mimeType,
                    ],
                ],
            ]
        case let .realtimeInputText(text):
            return [
                "realtimeInput": [
                    "text": text,
                ],
            ]
        case let .toolResponse(id, name, response):
            return [
                "toolResponse": [
                    "functionResponses": [[
                        "id": id,
                        "name": name,
                        "response": response,
                    ]],
                ],
            ]
        case let .sessionUpdate(payload):
            return [
                "sessionUpdate": payload,
            ]
        }
    }
}

// MARK: - Inbound frames (server → iOS)

/// Top-level envelope the server sends. We peek at the key names on the
/// first pass of JSONSerialization (`.mutableContainers` not needed —
/// we're just reading), then dispatch to a typed decoder per variant.
/// Keeping dispatch manual (not Decodable) because the sdk wraps each
/// frame in a single top-level key (`setupComplete` | `serverContent` |
/// `toolCall` | `usageMetadata` | `goAway` | `sessionResumptionUpdate`)
/// and Codable's associated-value enum decoding is clumsier than worth.
enum LiveInboundFrame {
    case setupComplete
    case serverContent(LiveServerContent)
    case toolCall(LiveToolCall)
    case usageMetadata(LiveUsageMetadata)
    /// Server is about to close the session (session too long, backend
    /// maintenance, etc.). Treated as "refresh now" signal.
    case goAway(timeBeforeDisconnectMs: Int?)
    /// Session resumption handle for seamless reconnection. Not yet used
    /// by Stir (we do fresh sessions on refresh) but parsed so it doesn't
    /// surface as an "unknown frame" warning.
    case sessionResumption
    /// Unknown top-level key — logged at debug level, not fatal. Keeps
    /// forward-compat when Google adds a new envelope we don't know yet.
    case unknown(key: String)

    // swiftlint:disable cyclomatic_complexity
    /// Parse all applicable frames from one WebSocket envelope. Gemini Live
    /// envelopes commonly carry MULTIPLE top-level keys in a single message
    /// — e.g., `{ serverContent: {...}, usageMetadata: {...} }` on the
    /// turn-complete frame. An earlier version returned on first match and
    /// silently dropped sibling keys; that lost every usageMetadata that
    /// arrived alongside serverContent, so downstream token/cost reporting
    /// always saw 0 (observed 2026-04-22 against a 36-generation prod run:
    /// every $ai_generation had $ai_input_tokens=0).
    ///
    /// Returns frames in order of dispatch dependency:
    ///   1. `setupComplete` — handshake gate.
    ///   2. `usageMetadata` — pure state update that must land before
    ///      anything that triggers `finalizeTurn()`. `{serverContent:
    ///      {turnComplete}, usageMetadata}` would otherwise POST 0
    ///      tokens because `finalizeTurn()` would fire before the
    ///      usage envelope was accumulated.
    ///   3. `toolCall` — must land BEFORE a same-envelope `serverContent`
    ///      with `turnComplete=true`, otherwise `finalizeTurn()` latches
    ///      `containedToolCall=false` and the belated `handleToolCall`
    ///      mis-tags the NEXT turn as `tool_call` (ADR 0012 gate split).
    ///      Gemini Live's documented envelope shape `{serverContent:
    ///      {turnComplete}, toolCall}` means "here's my tool call AND
    ///      I'm done" — the call belongs to the turn that's ending.
    ///      Trade-off: in the rare combined envelope `{audioChunks,
    ///      turnComplete, toolCall}`, the last audio chunks wait on the
    ///      tool dispatch round-trip (~500 ms) before enqueue. Still
    ///      audible; playback queue already has preceding chunks
    ///      buffered, and correctness of result-type tagging wins over
    ///      tail-audio promptness for a rare shape.
    ///   4. `serverContent` — content + the `turnComplete` trigger.
    static func parseAll(_ json: Any) -> [LiveInboundFrame] {
        guard let dict = json as? [String: Any] else { return [] }
        var frames: [LiveInboundFrame] = []

        if dict["setupComplete"] != nil {
            frames.append(.setupComplete)
        }
        // Side-data first so state-dependent handlers downstream see it.
        if let obj = dict["usageMetadata"] as? [String: Any] {
            frames.append(.usageMetadata(LiveUsageMetadata.parse(obj)))
        }
        // toolCall BEFORE serverContent so handleToolCall stamps
        // `turnContainedToolCall = true` before finalizeTurn latches it.
        // See ordering docstring above for the combined-envelope case.
        if let obj = dict["toolCall"] as? [String: Any] {
            frames.append(.toolCall(LiveToolCall.parse(obj)))
        }
        if let obj = dict["serverContent"] as? [String: Any] {
            frames.append(.serverContent(LiveServerContent.parse(obj)))
        }
        if let obj = dict["goAway"] as? [String: Any] {
            let ms = obj["timeBeforeDisconnectMs"] as? Int
                ?? (obj["timeBeforeDisconnect"] as? String).flatMap(Int.init)
            frames.append(.goAway(timeBeforeDisconnectMs: ms))
        }
        if dict["sessionResumptionUpdate"] != nil {
            frames.append(.sessionResumption)
        }

        // If we didn't recognize any known key, yield one `.unknown` so
        // the receive dispatcher's debug log fires. Otherwise stay
        // silent — unrecognized extra keys alongside known ones are
        // likely future-compat extensions and not worth alerting on.
        if frames.isEmpty, let firstKey = dict.keys.first {
            frames.append(.unknown(key: firstKey))
        }
        #if DEBUG
        // Log unknown-sibling keys at debug level so Gemini Live API
        // drift (new envelope types alongside known ones) shows up
        // before it becomes load-bearing. Doesn't fire on the common
        // single-key frames we already handle.
        let knownKeys: Set<String> = [
            "setupComplete", "serverContent", "toolCall", "usageMetadata",
            "goAway", "sessionResumptionUpdate",
        ]
        for k in dict.keys where !knownKeys.contains(k) {
            Logger.voice.debug("live_ws_unknown_sibling_key key=\(k, privacy: .public)")
        }
        #endif
        return frames
    }
    // swiftlint:enable cyclomatic_complexity
}

/// `serverContent` — model's turn output (audio + optional text +
/// optional completion flags).
struct LiveServerContent: Sendable, Equatable {
    /// Base64-encoded audio chunks. One frame can carry multiple inline
    /// audio parts; we concatenate in arrival order. `mimeType` is
    /// typically `audio/pcm;rate=24000` per Gemini docs.
    var audioChunks: [LiveAudioChunk] = []
    /// Optional inline text (rare in AUDIO mode; kept for the case
    /// where the model surfaces a typed response — we don't render it
    /// but log it for Sentry triage).
    var inlineText: String?
    /// Server-provided transcript of what the USER just said. Only
    /// populated when `inputAudioTranscription: {}` is in the setup.
    /// Extremely useful as a diagnostic: if Gemini isn't "hearing"
    /// the audio, this stays nil even on a speaking user.
    var inputTranscription: LiveTranscription?
    /// Server-provided transcript of what the MODEL is speaking back.
    /// Gated on `outputAudioTranscription: {}` in the setup.
    var outputTranscription: LiveTranscription?
    /// Server signals end-of-turn. iOS uses this to advance the state
    /// machine from `.modelSpeaking` back to `.ready`.
    var turnComplete: Bool = false
    /// Server interrupted itself (e.g. user barge-in via audio VAD).
    /// Rare — manual cancel is the primary interruption path.
    var interrupted: Bool = false
    /// Server emitted a grounding metadata frame. Logged only.
    var hasGroundingMetadata: Bool = false

    static func parse(_ obj: [String: Any]) -> LiveServerContent {
        var result = LiveServerContent()
        if let modelTurn = obj["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            for part in parts {
                if let inline = part["inlineData"] as? [String: Any],
                   let data = inline["data"] as? String {
                    let mime = inline["mimeType"] as? String ?? "audio/pcm;rate=24000"
                    result.audioChunks.append(LiveAudioChunk(base64: data, mimeType: mime))
                } else if let text = part["text"] as? String {
                    result.inlineText = (result.inlineText ?? "") + text
                }
            }
        }
        if let input = obj["inputTranscription"] as? [String: Any] {
            result.inputTranscription = LiveTranscription.parse(input)
        }
        if let output = obj["outputTranscription"] as? [String: Any] {
            result.outputTranscription = LiveTranscription.parse(output)
        }
        if let done = obj["turnComplete"] as? Bool, done {
            result.turnComplete = true
        }
        if let interrupted = obj["interrupted"] as? Bool, interrupted {
            result.interrupted = true
        }
        if obj["groundingMetadata"] != nil {
            result.hasGroundingMetadata = true
        }
        return result
    }
}

/// Partial transcription frame. `text` accumulates across frames in the
/// same turn; `finished` flips true on the last delta.
struct LiveTranscription: Sendable, Equatable {
    let text: String
    let finished: Bool

    static func parse(_ obj: [String: Any]) -> LiveTranscription {
        LiveTranscription(
            text: obj["text"] as? String ?? "",
            finished: obj["finished"] as? Bool ?? false,
        )
    }
}

struct LiveAudioChunk: Sendable, Equatable {
    let base64: String
    let mimeType: String
}

/// `toolCall` — model wants iOS to run a function. Stir's mint baked
/// three tools: `substitution_check`, `start_timer`, `advance_step`.
/// Tools are synchronous on 3.1 Flash Live (one call in flight at a
/// time, CLAUDE.md §sharp-edge #12) so the array has length 1 in
/// practice but we parse as an array to match the wire.
struct LiveToolCall: Sendable, Equatable {
    let functionCalls: [LiveFunctionCall]

    static func parse(_ obj: [String: Any]) -> LiveToolCall {
        guard let rawArr = obj["functionCalls"] as? [[String: Any]] else {
            return LiveToolCall(functionCalls: [])
        }
        let calls = rawArr.compactMap { LiveFunctionCall.parse($0) }
        return LiveToolCall(functionCalls: calls)
    }
}

/// `@unchecked Sendable` because `args: [String: Any]` is heterogeneous
/// (String/Int/NSNumber in practice; never mutable closures or refs).
/// The dict is `let`-immutable after parse — no races are possible.
struct LiveFunctionCall: @unchecked Sendable, Equatable {
    /// Opaque id the server expects back on toolResponse.functionResponse.id.
    /// Always a string on the wire; if we see a numeric, we stringify.
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

    static func parse(_ obj: [String: Any]) -> LiveFunctionCall? {
        guard let name = obj["name"] as? String else { return nil }
        // `id` is a string per Google's current wire but some proto
        // encodings emit it as a number. Normalize both to String.
        let id: String
        if let s = obj["id"] as? String {
            id = s
        } else if let n = obj["id"] as? NSNumber {
            id = n.stringValue
        } else {
            return nil
        }
        let args = (obj["args"] as? [String: Any]) ?? [:]
        return LiveFunctionCall(id: id, name: name, args: args)
    }

    // MARK: - Typed args for Stir's three tools

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

    /// `set_step.step_number` — nominally 1-indexed int arg. Gemini
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

/// `usageMetadata` — per-turn token accounting. Populated on every
/// response frame per Gemini docs; Stir uses it to drive the
/// `voice_session_token_snapshot` telemetry + the 80k hard cap
/// enforcement (CLAUDE.md §Live constants).
struct LiveUsageMetadata: Sendable, Equatable {
    /// Total input tokens (audio + text + system prompt + cached history).
    let promptTokenCount: Int
    /// Total output tokens (audio + text).
    let responseTokenCount: Int
    /// Cumulative tokens for the session so far. The spike doc noted
    /// this is NOT present in every frame; absent = "same as last".
    let totalTokenCount: Int

    /// Breakdown per modality (audio/text/image). Only recorded when
    /// we need it for cost tracking — present by default on Live.
    let promptAudioTokens: Int?
    let promptTextTokens: Int?
    let responseAudioTokens: Int?
    let responseTextTokens: Int?
    /// Portion of `promptTokenCount` that was served from Gemini's
    /// content cache (system prompt re-use). Billed at a discounted
    /// rate. `promptTokensDetails` typically lists only the fresh AUDIO
    /// chunk and omits the cached portion; without parsing this field
    /// we silently drop cached tokens from cost attribution — observed
    /// gap 2026-04-22: 185–261 tokens per turn unaccounted.
    let cachedContentTokenCount: Int?

    static func parse(_ obj: [String: Any]) -> LiveUsageMetadata {
        let prompt = obj["promptTokenCount"] as? Int ?? 0
        let response = obj["responseTokenCount"] as? Int ?? 0
        let total = obj["totalTokenCount"] as? Int ?? (prompt + response)
        let cached = obj["cachedContentTokenCount"] as? Int

        var pAudio: Int?
        var pText: Int?
        if let arr = obj["promptTokensDetails"] as? [[String: Any]] {
            for item in arr {
                let mod = (item["modality"] as? String) ?? ""
                let count = item["tokenCount"] as? Int ?? 0
                if mod == "AUDIO" { pAudio = count }
                if mod == "TEXT" { pText = count }
            }
        }

        var rAudio: Int?
        var rText: Int?
        if let arr = obj["responseTokensDetails"] as? [[String: Any]] {
            for item in arr {
                let mod = (item["modality"] as? String) ?? ""
                let count = item["tokenCount"] as? Int ?? 0
                if mod == "AUDIO" { rAudio = count }
                if mod == "TEXT" { rText = count }
            }
        }

        return LiveUsageMetadata(
            promptTokenCount: prompt,
            responseTokenCount: response,
            totalTokenCount: total,
            promptAudioTokens: pAudio,
            promptTextTokens: pText,
            responseAudioTokens: rAudio,
            responseTextTokens: rText,
            cachedContentTokenCount: cached,
        )
    }
}
