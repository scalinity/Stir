// VoiceTurnUsageDTOTests
//
// Wire-format tests for the VoiceTurnUsageRequest DTO and its
// TurnUsage sub-struct. Locks in snake_case serialization that the
// Edge Function's Zod schema accepts (per ADR 0009).

import Foundation
import XCTest
@testable import Stir

final class VoiceTurnUsageDTOTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    func test_voiceTurnUsage_encodesWithSnakeCaseKeys() throws {
        let endedAt = Date(timeIntervalSince1970: 1_713_800_000)
        let body = VoiceTurnUsageRequest(
            sessionID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            turns: [
                .init(
                    turnIndex: 1,
                    promptTokensText: 1000,
                    promptTokensAudio: 1150,
                    promptTokensTotal: 2350,
                    promptTokensCached: nil,
                    responseTokensText: 0,
                    responseTokensAudio: 150,
                    responseTokensTotal: 160,
                    latencyMS: 1400,
                    endedReason: .turnComplete,
                    promptVersion: "1.0.0",
                    path: .liveAPI,
                    endedAt: endedAt,
                ),
            ],
        )
        let data = try encoder.encode(body)
        let str = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(str.contains("\"session_id\""))
        XCTAssertTrue(str.contains("\"turn_index\":1"))
        XCTAssertTrue(str.contains("\"prompt_tokens_text\":1000"))
        XCTAssertTrue(str.contains("\"prompt_tokens_audio\":1150"))
        XCTAssertTrue(str.contains("\"prompt_tokens_total\":2350"))
        XCTAssertTrue(str.contains("\"response_tokens_text\":0"))
        XCTAssertTrue(str.contains("\"response_tokens_audio\":150"))
        XCTAssertTrue(str.contains("\"response_tokens_total\":160"))
        XCTAssertTrue(str.contains("\"latency_ms\":1400"))
        XCTAssertTrue(str.contains("\"prompt_version\":\"1.0.0\""))
        XCTAssertTrue(str.contains("\"ended_reason\":\"turn_complete\""))
        XCTAssertTrue(str.contains("\"path\":\"live_api\""))
        XCTAssertTrue(str.contains("\"ended_at\""))
        // When caching didn't fire, the field is omitted on the wire
        // (backend Zod has prompt_tokens_cached as optional). Pins the
        // encodeIfPresent behavior so a regression to always-emit doesn't
        // poison dashboards with zero-count rows masquerading as caching.
        XCTAssertFalse(
            str.contains("\"prompt_tokens_cached\""),
            "nil cached-tokens must be omitted from wire, got: \(str)",
        )
    }

    func test_voiceTurnUsage_whenCachingFired_encodesPromptTokensCached() throws {
        // Gemini Live implicit caching status is the gating measurement
        // for the spec §9 cap-reversal trigger. If this field doesn't
        // encode when non-nil, the backend can't persist it and dashboards
        // can't compute cachedContentTokenCount / promptTokenCount ratio.
        let endedAt = Date(timeIntervalSince1970: 1_713_800_000)
        let body = VoiceTurnUsageRequest(
            sessionID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            turns: [
                .init(
                    turnIndex: 2,
                    promptTokensText: 1000,
                    promptTokensAudio: 1150,
                    promptTokensTotal: 2350,
                    promptTokensCached: 1_800,
                    responseTokensText: 0,
                    responseTokensAudio: 150,
                    responseTokensTotal: 160,
                    latencyMS: 1200,
                    endedReason: .turnComplete,
                    promptVersion: "1.6.0",
                    path: .liveAPI,
                    endedAt: endedAt,
                ),
            ],
        )
        let data = try encoder.encode(body)
        let str = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(
            str.contains("\"prompt_tokens_cached\":1800"),
            "non-nil cached-tokens must encode as snake_case; got: \(str)",
        )
    }

    func test_endedReason_enumRawValues_matchBackendZodValues() {
        // Zod enum on backend: 'turn_complete' | 'tool_response' | 'error' | 'interrupted'.
        // If any case rawValue drifts, the backend returns VAL-01 on iOS's fire-and-forget
        // POST and the capture silently drops — so the iOS test guards the contract.
        XCTAssertEqual(VoiceTurnUsageRequest.TurnUsage.EndedReason.turnComplete.rawValue, "turn_complete")
        XCTAssertEqual(VoiceTurnUsageRequest.TurnUsage.EndedReason.toolResponse.rawValue, "tool_response")
        XCTAssertEqual(VoiceTurnUsageRequest.TurnUsage.EndedReason.error.rawValue, "error")
        XCTAssertEqual(VoiceTurnUsageRequest.TurnUsage.EndedReason.interrupted.rawValue, "interrupted")
    }

    func test_path_enumRawValues_matchBackendZodValues() {
        // Zod enum on backend: z.enum(['live_api']). Reopening the enum
        // requires an ADR (AIDispatchDTOs.swift docstring). If/when
        // `geminiFallback` is added, re-enable the assertion alongside
        // the backend schema change.
        XCTAssertEqual(VoiceTurnUsageRequest.TurnUsage.Path.liveAPI.rawValue, "live_api")
    }

    func test_liveTurnSummary_carriesAllTokenBreakdowns() {
        // Close-summary $ai_trace aggregation relies on LiveTurnSummary
        // preserving the per-modality breakdown AND the raw totals. If
        // totals drop, VM's total_prompt_tokens / total_response_tokens
        // under-report by the AUDIO-mode per-pass overhead.
        let summary = LiveTurnSummary(
            turnIndex: 3,
            promptTokensText: 100,
            promptTokensAudio: 900,
            promptTokensTotal: 1200,
            responseTokensText: 10,
            responseTokensAudio: 140,
            responseTokensTotal: 160,
            latencyMs: 1800,
            latencyTtfaMs: 250,
            containedToolCall: false,
            endedReason: .turnComplete,
            endedAt: Date(),
        )
        XCTAssertEqual(summary.promptTokensText, 100)
        XCTAssertEqual(summary.promptTokensAudio, 900)
        XCTAssertEqual(summary.promptTokensTotal, 1200)
        XCTAssertEqual(summary.responseTokensText, 10)
        XCTAssertEqual(summary.responseTokensAudio, 140)
        XCTAssertEqual(summary.responseTokensTotal, 160)
        XCTAssertFalse(summary.containedToolCall)
        // Totals exceed text+audio sums by the AUDIO-mode per-pass
        // overhead (CLAUDE.md sharp-edge #15): 1200 - (100 + 900) = 200
        // on prompt side, 160 - (10 + 140) = 10 on response side.
        XCTAssertGreaterThanOrEqual(summary.promptTokensTotal, summary.promptTokensText + summary.promptTokensAudio)
        XCTAssertGreaterThanOrEqual(summary.responseTokensTotal, summary.responseTokensText + summary.responseTokensAudio)
    }
}
