// AIDispatch
//
// Central dispatcher for Gemini-adjacent Supabase Edge Function calls.
// Wraps `SupabaseSessionClient` to inherit AUTH-01 silent-retry + 5xx
// backoff for both the non-streaming (pantry-parse) and streaming
// (dinner-solve SSE) paths.
//
// Step-3 methods:
//   - pantryParse(image:, mimeType:, householdHash:) -> PantryParseResponse
//   - dinnerSolve(request:) -> AsyncThrowingStream<DinnerSolveEvent, Error>
//
// All iOS error code mapping lives here; callers get typed StirError
// values, not URL/JSON mechanics.

import Foundation
import OSLog

actor AIDispatch {
    private let session: SupabaseSessionClient
    private let config: AppConfig

    init(session: SupabaseSessionClient, config: AppConfig) {
        self.session = session
        self.config = config
    }

    // MARK: - Pantry parse

    func pantryParse(
        clientRequestID: UUID,
        imageData: Data,
        mimeType: String,
        householdProfileHash: String?,
    ) async throws -> PantryParseResponse {
        let body = PantryParseRequest(
            clientRequestID: clientRequestID,
            imageBase64: imageData.base64EncodedString(),
            imageMimeType: mimeType,
            imageCount: 1,
            householdProfileHash: householdProfileHash,
        )
        let url = config.supabase.url.appendingPathComponent("/functions/v1/pantry-parse")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "content-type")
        request.addValue("application/json", forHTTPHeaderField: "accept")
        do {
            request.httpBody = try JSONEncoder.stir.encode(body)
        } catch {
            throw StirError.validation(fieldErrors: [], message: "failed to encode pantry-parse body: \(error.localizedDescription)")
        }

        Logger.aiDispatch.info("pantry_parse_dispatch request_id=\(clientRequestID.uuidString, privacy: .public)")
        let response: PantryParseResponse = try await session.performAuthenticated(request)
        Logger.aiDispatch.info(
            "pantry_parse_complete ingredients=\(response.ingredients.count, privacy: .public) retry_count=\(response.retryCount, privacy: .public)",
        )
        return response
    }

    // MARK: - Substitution

    /// Non-streaming single-shot substitution call. Hard-rule checks run
    /// server-side AND we mirror the constraint_safe boolean into the
    /// returned enum so the UI branches on a typed value, not the wire
    /// shape.
    func substitution(request body: SubstitutionRequest) async throws -> SubstitutionResult {
        let url = config.supabase.url.appendingPathComponent("/functions/v1/substitution")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "content-type")
        request.addValue("application/json", forHTTPHeaderField: "accept")
        // 20s is well above Gemini's p95 server latency (~4s per the
        // April 2026 spike) and well below URLSession.shared's 60s default.
        // Prevents the Substitution Sheet from hanging in `.requesting`
        // on a half-open TCP connection mid-cook (CA2-R4).
        request.timeoutInterval = 20
        do {
            request.httpBody = try JSONEncoder.stir.encode(body)
        } catch {
            throw StirError.validation(
                fieldErrors: [],
                message: "failed to encode substitution body: \(error.localizedDescription)",
            )
        }

        Logger.aiDispatch.info("substitution_dispatch sub_event_id=\(body.subEventID.uuidString, privacy: .public)")
        let response: SubstitutionResponse = try await session.performAuthenticated(request)
        Logger.aiDispatch.info(
            "substitution_complete safe=\(response.constraintSafe, privacy: .public) retry=\(response.retryCount, privacy: .public) latency_ms=\(response.latencyMS, privacy: .public)",
        )

        if response.constraintSafe {
            return .safe(
                subEventID: response.subEventID,
                text: response.substitutionText,
                amountConversion: response.amountConversion,
                reasoning: response.reasoning,
                confidence: response.confidence,
                promptVersion: response.promptVersion,
            )
        }
        return .unsafe(
            subEventID: response.subEventID,
            reason: response.constraintViolationReason ?? "Hard dietary or equipment constraint",
            message: response.substitutionText,
            promptVersion: response.promptVersion,
        )
    }

    // MARK: - Realtime Session mint (step 6 C.2 — Gemini Live)

    /// POST /v1/ai/realtime-session. Mints a single-use Gemini Live
    /// ephemeral token for one Cook Session. Backend handles the actual
    /// mint to Google's `/v1alpha/auth_tokens` using the paid-tier
    /// GEMINI_API_KEY (never leaves Supabase). Response includes a
    /// ready-to-open `ws_url` with `access_token` pre-embedded.
    ///
    /// Timeout is 15s — slightly tighter than cook-turn because mint
    /// p95 measured ~1.2s against paid tier, and a mid-session refresh
    /// hanging 15s would leak audibly past the seamless-handoff budget.
    ///
    /// Throws `StirError.server(code: .aiVoice01)` on upstream Gemini
    /// outage (backend maps mint 5xx to AI-VOICE-01) so iOS can trigger
    /// the fall-back to C.3 path cleanly.
    func realtimeSession(request body: RealtimeSessionRequest) async throws -> RealtimeSessionResponse {
        let url = config.supabase.url.appendingPathComponent("/functions/v1/realtime-session")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "content-type")
        request.addValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = 15
        do {
            request.httpBody = try JSONEncoder.stir.encode(body)
        } catch {
            throw StirError.validation(
                fieldErrors: [],
                message: "failed to encode realtime-session body: \(error.localizedDescription)",
            )
        }

        Logger.aiDispatch.info(
            "realtime_session_mint request_id=\(body.clientRequestID.uuidString, privacy: .public)",
        )
        let response: RealtimeSessionResponse = try await session.performAuthenticated(request)
        Logger.aiDispatch.info(
            "realtime_session_minted session_id=\(response.sessionID, privacy: .public) expires_at=\(response.expiresAt, privacy: .public)",
        )
        return response
    }

    // MARK: - Cook Turn (step 6 — Live fallback)

    /// POST /v1/ai/cook-turn. Sent by SpeechFallbackService after on-device
    /// transcription; returns a spoken response + optional suggested UI
    /// action. Backend is gated on voice_cook_mode entitlement (Premium+);
    /// Free users hit ENT-VOICE-01 before we ever get here because iOS
    /// guards the mic affordance.
    ///
    /// Timeout matches substitution (20s) — backend p95 ~2s, and a
    /// mid-cook voice-fallback that hangs past 20s is worse than a
    /// quick NET-01 the user can retry.
    func cookTurn(request body: CookTurnRequest) async throws -> CookTurnResponse {
        let url = config.supabase.url.appendingPathComponent("/functions/v1/cook-turn")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "content-type")
        request.addValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = 20
        do {
            request.httpBody = try JSONEncoder.stir.encode(body)
        } catch {
            throw StirError.validation(
                fieldErrors: [],
                message: "failed to encode cook-turn body: \(error.localizedDescription)",
            )
        }

        Logger.aiDispatch.info(
            "cook_turn_dispatch request_id=\(body.clientRequestID.uuidString, privacy: .public)",
        )
        let response: CookTurnResponse = try await session.performAuthenticated(request)
        Logger.aiDispatch.info(
            "cook_turn_complete action=\(response.suggestedAction.rawValue, privacy: .public) retry=\(response.retryCount, privacy: .public) latency_ms=\(response.latencyMS, privacy: .public)",
        )
        return response
    }

    // MARK: - Recipe Import (step 7)

    /// POST /v1/ai/recipe-import. Dispatches the four source_type paths
    /// (url | share_sheet | screenshot_ocr | pasted_text) and returns
    /// either a completed RecipeImportResponse with a parsed recipe, or a
    /// queued response when the backend decided to process async
    /// (pasted content > ~8KiB). The caller's RecipeImport entity state
    /// machine is driven from the returned `status`.
    ///
    /// The backend applies its own ai_response_cache idempotency on
    /// `import_id`, so a retry with the same id replays the cached
    /// response instead of burning another Gemini call.
    func recipeImport(request body: RecipeImportRequest) async throws -> RecipeImportResponse {
        let url = config.supabase.url.appendingPathComponent("/functions/v1/recipe-import")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "content-type")
        request.addValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = 20
        do {
            request.httpBody = try JSONEncoder.stir.encode(body)
        } catch {
            throw StirError.validation(
                fieldErrors: [],
                message: "failed to encode recipe-import body: \(error.localizedDescription)",
            )
        }

        Logger.aiDispatch.info(
            "recipe_import_dispatch import_id=\(body.importID.uuidString, privacy: .public) source_type=\(body.sourceType.rawValue, privacy: .public)",
        )
        let response: RecipeImportResponse = try await session.performAuthenticated(request)
        Logger.aiDispatch.info(
            "recipe_import_complete status=\(response.status.rawValue, privacy: .public) retry=\(response.retryCount, privacy: .public) parse_quality=\(response.recipe?.parseQuality.rawValue ?? "n/a", privacy: .public)",
        )
        return response
    }

    // MARK: - Grocery Generate (step 7)

    /// POST /v1/ai/grocery-generate. Unmetered across tiers. Returns the
    /// Gemini-generated diff of recipe ingredients against pantry snapshot
    /// with `priority` populated on every missing_item (spec §4.17
    /// required). Dedupe + aisle grouping are handled server-side; iOS
    /// may still apply a secondary dedupe pass via GroceryRepository for
    /// insurance.
    func groceryGenerate(request body: GroceryGenerateRequest) async throws -> GroceryGenerateResponse {
        let url = config.supabase.url.appendingPathComponent("/functions/v1/grocery-generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "content-type")
        request.addValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = 15
        do {
            request.httpBody = try JSONEncoder.stir.encode(body)
        } catch {
            throw StirError.validation(
                fieldErrors: [],
                message: "failed to encode grocery-generate body: \(error.localizedDescription)",
            )
        }

        Logger.aiDispatch.info(
            "grocery_generate_dispatch source_id=\(body.sourceID.uuidString, privacy: .public) source_type=\(body.sourceType.rawValue, privacy: .public)",
        )
        let response: GroceryGenerateResponse = try await session.performAuthenticated(request)
        Logger.aiDispatch.info(
            "grocery_generate_complete missing=\(response.missingItems.count, privacy: .public) already=\(response.alreadyHave.count, privacy: .public) retry=\(response.retryCount, privacy: .public)",
        )
        return response
    }

    // MARK: - Push Register (step 7)

    /// POST /v1/push/register. Called from iOS on first APNs token grant
    /// and on every prefs-change in Settings → Notifications. Idempotent
    /// by (canonical_user_key, installation_id, token, prefs) — reposts
    /// with identical payload are a no-op UPDATE.
    func pushRegister(request body: PushRegisterRequest) async throws -> PushRegisterResponse {
        let url = config.supabase.url.appendingPathComponent("/functions/v1/push-register")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "content-type")
        request.addValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = 10
        do {
            request.httpBody = try JSONEncoder.stir.encode(body)
        } catch {
            throw StirError.validation(
                fieldErrors: [],
                message: "failed to encode push-register body: \(error.localizedDescription)",
            )
        }

        Logger.aiDispatch.info(
            "push_register_dispatch env=\(body.environment.rawValue, privacy: .public)",
        )
        let response: PushRegisterResponse = try await session.performAuthenticated(request)
        Logger.aiDispatch.info(
            "push_register_complete installation_id=\(response.installationID, privacy: .public) env=\(response.environment, privacy: .public)",
        )
        return response
    }

    // MARK: - Dinner solve (SSE)

    /// Returns an AsyncThrowingStream emitting DinnerSolveEvents as they
    /// arrive from the SSE handler. Caller consumes with `for try await`.
    ///
    /// Captured `session` and `config` are the actor's `let` properties;
    /// hoisting them into local constants makes the actor-isolation intent
    /// explicit at the capture site, so this compiles cleanly without
    /// `nonisolated` and without risk if either property ever flips to var.
    func dinnerSolve(
        request body: DinnerSolveRequest,
    ) -> AsyncThrowingStream<DinnerSolveEvent, Error> {
        let capturedSession = session
        let capturedConfig = config
        return AsyncThrowingStream<DinnerSolveEvent, Error> { continuation in
            let task = Task<Void, Never> { [session = capturedSession, config = capturedConfig] in
                do {
                    let url = config.supabase.url.appendingPathComponent("/functions/v1/dinner-solve")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.addValue("application/json", forHTTPHeaderField: "content-type")
                    request.httpBody = try JSONEncoder.stir.encode(body)

                    let (_, bytes) = try await session.performAuthenticatedStream(request)

                    // SSE parsing: read line by line; events are blank-line
                    // delimited; each event has `event: <name>` + `data: <json>`.
                    var currentEvent: String = ""
                    var dataBuffer: String = ""

                    for try await line in bytes.lines {
                        if line.isEmpty {
                            // End of one event — emit to continuation.
                            if !currentEvent.isEmpty, !dataBuffer.isEmpty {
                                try handleEvent(
                                    event: currentEvent,
                                    dataJSON: dataBuffer,
                                    continuation: continuation,
                                )
                            }
                            currentEvent = ""
                            dataBuffer = ""
                            continue
                        }
                        if line.hasPrefix(":") {
                            // SSE keepalive comment — ignore.
                            continue
                        }
                        if line.hasPrefix("event:") {
                            currentEvent = String(line.dropFirst("event:".count))
                                .trimmingCharacters(in: .whitespaces)
                            continue
                        }
                        if line.hasPrefix("data:") {
                            let chunk = String(line.dropFirst("data:".count))
                                .trimmingCharacters(in: .whitespaces)
                            if dataBuffer.isEmpty {
                                dataBuffer = chunk
                            } else {
                                dataBuffer += "\n" + chunk
                            }
                            continue
                        }
                        // Any other line — ignore (unknown field).
                    }
                    // Final flush if the stream ended without trailing blank line.
                    if !currentEvent.isEmpty, !dataBuffer.isEmpty {
                        try handleEvent(
                            event: currentEvent,
                            dataJSON: dataBuffer,
                            continuation: continuation,
                        )
                    }
                    continuation.finish()
                } catch {
                    Logger.aiDispatch.error(
                        "dinner_solve_stream_failed: \(error.localizedDescription, privacy: .public)",
                    )
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

// MARK: - SSE event decoding

private func handleEvent(
    event: String,
    dataJSON: String,
    continuation: AsyncThrowingStream<DinnerSolveEvent, Error>.Continuation,
) throws {
    if let evt = try decodeSSEEvent(event: event, dataJSON: dataJSON) {
        continuation.yield(evt)
    }
}

/// Pure SSE event decoder — given an `event:` tag and its `data:` JSON
/// payload, decode to a DinnerSolveEvent or nil (unknown event type).
/// Exposed internally for unit testing.
enum SSEParseError: Error {
    case notUTF8
}

func decodeSSEEvent(event: String, dataJSON: String) throws -> DinnerSolveEvent? {
    guard let data = dataJSON.data(using: .utf8) else {
        throw SSEParseError.notUTF8
    }
    let decoder = JSONDecoder.stir
    switch event {
    case "dish":
        let dish = try decoder.decode(DishCard.self, from: data)
        return .dish(dish)
    case "error":
        let slot = try decoder.decode(DinnerSolveSlotError.self, from: data)
        return .slotError(rank: slot.rank, code: slot.code)
    case "done":
        let done = try decoder.decode(DinnerSolveDoneFrame.self, from: data)
        return .done(
            solveRequestID: done.solveRequestID,
            totalCostUSD: done.totalCostUSD,
            dishesReturned: done.dishesReturned,
            retryCount: done.retryCount,
            promptVersion: done.promptVersion,
        )
    default:
        Logger.aiDispatch.warning("unknown SSE event: \(event, privacy: .public)")
        return nil
    }
}

// MARK: - Logger subsystem extension

extension Logger {
    static let aiDispatch = Logger(subsystem: "com.scalinity.stir", category: "AIDispatch")
}
