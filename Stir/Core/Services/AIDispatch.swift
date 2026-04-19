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

    // MARK: - Dinner solve (SSE)

    /// Returns an AsyncThrowingStream emitting DinnerSolveEvents as they
    /// arrive from the SSE handler. Caller consumes with `for try await`.
    nonisolated func dinnerSolve(
        request body: DinnerSolveRequest,
    ) -> AsyncThrowingStream<DinnerSolveEvent, Error> {
        AsyncThrowingStream<DinnerSolveEvent, Error> { continuation in
            let task = Task<Void, Never> { [session, config] in
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
