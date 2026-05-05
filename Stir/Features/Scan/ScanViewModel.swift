// ScanViewModel
//
// Drives the scan → parse → review state machine. State is @Observable so
// SwiftUI re-renders whenever phase or ingredients change.
//
// Flow per CLAUDE.md + spec §5 Camera pantry scan:
//   idle → capturing → parsing → review → confirmed
//   with error edges at any point recoverable back to an earlier phase.
//
// Persistence: on confirmFromReview(), upserts selected ingredients into
// PantryItem via PantryItemRepository so the subsequent solve call can
// carry the household's now-richer pantry context.

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class ScanViewModel {
    enum Phase: Sendable, Equatable {
        case idle
        case capturing
        case parsing
        case review
        case confirmed
        case error(message: String, recoverable: Bool)
    }

    struct Ingredient: Identifiable, Sendable, Equatable {
        let id: UUID
        var displayName: String
        var canonicalSlug: String?
        var confidence: PantryParseResponse.PantryItemConfidence
        var amountText: String?

        init(
            id: UUID = UUID(),
            displayName: String,
            canonicalSlug: String? = nil,
            confidence: PantryParseResponse.PantryItemConfidence,
            amountText: String? = nil,
        ) {
            self.id = id
            self.displayName = displayName
            self.canonicalSlug = canonicalSlug
            self.confidence = confidence
            self.amountText = amountText
        }

        init(from wire: PantryParseResponse.ParsedIngredient) {
            self.id = wire.id
            self.displayName = wire.displayName
            self.canonicalSlug = wire.canonicalSlug
            self.confidence = wire.confidence
            self.amountText = wire.amountText
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var ingredients: [Ingredient] = []
    private(set) var parseID: UUID?
    private(set) var lastLatencyMS: Int?
    private(set) var overallConfidence: Double?
    /// JPEG bytes of the most recent capture. Held here so the review
    /// screen can render a thumbnail of "what we looked at" without
    /// duplicating capture-side state. UIImage decoding happens in the
    /// view; this is just the wire data. Cleared on `resetToPrimer`.
    private(set) var capturedImageData: Data?

    private let aiDispatch: AIDispatch
    private let pantryRepo: PantryItemRepository
    private let householdStore: CurrentHouseholdStore
    private let entitlements: EntitlementService

    init(
        aiDispatch: AIDispatch,
        pantryRepo: PantryItemRepository,
        householdStore: CurrentHouseholdStore,
        entitlements: EntitlementService,
    ) {
        self.aiDispatch = aiDispatch
        self.pantryRepo = pantryRepo
        self.householdStore = householdStore
        self.entitlements = entitlements
    }

    // MARK: - Phase transitions

    func enterCapturing() {
        phase = .capturing
    }

    /// Stash the captured JPEG so the review screen can render a
    /// thumbnail. Caller passes `nil` to clear (e.g. retake flow).
    func setCapturedImageData(_ data: Data?) {
        capturedImageData = data
    }

    /// Submit a captured image for AI parsing.
    func submitCapturedImage(_ data: Data, mimeType: String) async {
        phase = .parsing
        let clientRequestID = UUID()

        PostHogClient.shared.capture(.scanSubmitted, properties: [
            "client_request_id": clientRequestID.uuidString,
            "image_bytes": data.count,
        ])

        do {
            let started = Date()
            let response = try await aiDispatch.pantryParse(
                clientRequestID: clientRequestID,
                imageData: data,
                mimeType: mimeType,
                // TODO(step-4): compute household hash so cache invalidates
                // when DietaryRule/KitchenEquipment changes mid-session.
                householdProfileHash: nil,
            )
            let latency = Int(Date().timeIntervalSince(started) * 1000)

            self.ingredients = response.ingredients.map(Ingredient.init(from:))
            self.parseID = response.parseID
            self.lastLatencyMS = response.latencyMS
            self.overallConfidence = response.overallConfidence
            self.phase = .review

            let avgConfidence = response.ingredients.isEmpty
                ? 0.0
                : response.ingredients.reduce(0.0) { $0 + confidenceWeight($1.confidence) } /
                  Double(response.ingredients.count)

            PostHogClient.shared.capture(.scanParseCompleted, properties: [
                "parse_id": response.parseID.uuidString,
                "ingredient_count": response.ingredients.count,
                "overall_confidence": response.overallConfidence,
                "parse_confidence_avg": avgConfidence,
                "latency_ms": latency,
                "retry_count": response.retryCount,
                "prompt_version": response.promptVersion,
            ])
        } catch StirError.rateLimited(_, let message) {
            self.phase = .error(message: message, recoverable: false)
            PostHogClient.shared.capture(.aiRequestFailed, properties: ["code": "RATE-01", "feature": "pantry_parse"])
        } catch StirError.entitlementRequired(let code, let message) {
            self.phase = .error(message: message, recoverable: false)
            PostHogClient.shared.capture(.aiRequestFailed, properties: ["code": code.rawValue, "feature": "pantry_parse"])
        } catch StirError.server(let code, let message, _) {
            self.phase = .error(message: message, recoverable: code != .val01)
            PostHogClient.shared.capture(.aiRequestFailed, properties: ["code": code.rawValue, "feature": "pantry_parse"])
        } catch StirError.validation(_, let message) {
            self.phase = .error(message: "Something went wrong scanning. Try again.", recoverable: false)
            Logger.scanFeature.error("VAL-01 on pantry-parse: \(message, privacy: .public)")
        } catch {
            self.phase = .error(message: "Couldn't reach Stir right now. Check your connection and try again.", recoverable: true)
            Logger.scanFeature.error("scan submit failed: \(error.localizedDescription, privacy: .public)")
            PostHogClient.shared.capture(.aiRequestFailed, properties: ["code": "NET-01", "feature": "pantry_parse"])
        }
    }

    // MARK: - Chip edits in review

    /// Maximum grapheme-cluster count for a manually-entered or edited
    /// ingredient name. 32 chars is past any realistic culinary label
    /// ("extra-virgin olive oil" is 22) and caps adversarial input from
    /// inflating every downstream dinner-solve prompt. Review finding
    /// W-B W10 (CA2).
    static let ingredientNameMaxLength = 32

    /// UTF-8 byte cap for an ingredient name. Pairs with the grapheme
    /// cap the same way the onboarding dislike caps pair (user-visible
    /// axis + payload-byte axis). 64 bytes = ~21 CJK chars or 64 ASCII.
    static let ingredientNameMaxBytes = 64

    /// Clamp `raw` to within both caps. Trims whitespace, then drops
    /// from the grapheme-count limit down, then from the UTF-8 byte
    /// limit down. Returns empty for all-whitespace input (caller
    /// interprets empty as "delete").
    private static func clampedIngredientName(_ raw: String) -> String {
        var bounded = String(
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(ingredientNameMaxLength),
        )
        while bounded.utf8.count > ingredientNameMaxBytes, !bounded.isEmpty {
            bounded = String(bounded.dropLast())
        }
        return bounded
    }

    func editIngredient(id: UUID, newName: String) {
        guard let idx = ingredients.firstIndex(where: { $0.id == id }) else { return }
        let bounded = Self.clampedIngredientName(newName)
        if bounded.isEmpty {
            // Clearing the field is interpreted as delete — matches the
            // context-menu delete affordance without needing two gestures.
            deleteIngredient(id: id)
            return
        }
        ingredients[idx].displayName = bounded
        ingredients[idx].confidence = .confirmed // user typed it → confident
        PostHogClient.shared.capture(.ingredientCorrected, properties: [
            "action": "edit",
            "final_name_length": bounded.count,
        ])
    }

    func deleteIngredient(id: UUID) {
        ingredients.removeAll { $0.id == id }
        PostHogClient.shared.capture(.ingredientCorrected, properties: ["action": "delete"])
    }

    func addIngredientManually(_ name: String) {
        let bounded = Self.clampedIngredientName(name)
        guard !bounded.isEmpty else { return }
        ingredients.append(Ingredient(
            displayName: bounded,
            confidence: .confirmed,
        ))
        PostHogClient.shared.capture(.ingredientCorrected, properties: [
            "action": "add",
            "name_length": bounded.count,
        ])
    }

    /// Ingredients + parse_id threaded into the subsequent solve call.
    struct ConfirmedScanResult: Sendable {
        let ingredients: [DinnerSolveRequest.IngredientLite]
        let parseID: UUID?
    }

    /// Persist confirmed ingredients into the user's PantryItem CloudKit store.
    /// Returns the IngredientLite array + parseID that SolveViewModel uses for
    /// the subsequent /v1/ai/dinner-solve call. parseID is what links the
    /// downstream solve's ai_request_log row to the original scan's row, so
    /// cost analysis can trace scan → solve funnels.
    @discardableResult
    func confirmFromReview() async -> ConfirmedScanResult {
        guard let household = householdStore.profile else {
            Logger.scanFeature.warning("confirm called without household — dropping")
            phase = .error(message: "Household profile missing. Please restart the app.", recoverable: false)
            return ConfirmedScanResult(ingredients: [], parseID: nil)
        }

        let scanInputs = ingredients.map { ing in
            PantryItemRepository.ScanIngredient(
                displayName: ing.displayName,
                canonicalSlug: ing.canonicalSlug,
                amountText: ing.amountText,
                confidence: confidenceWeight(ing.confidence),
                parseConfidence: translate(ing.confidence),
            )
        }
        do {
            // Cap-aware upsert: Free 25 / Premium 250 / Pro 1000 from
            // EntitlementService. Without this pair the repo would
            // happily insert unbounded `.remembered` rows from a
            // staple-heavy scan, breaking the standing-cap the manual-
            // add path enforces. See PantryItemRepository docstring +
            // review C1.
            let usedRemembered = (try? pantryRepo.countRemembered(for: household)) ?? 0
            let cap = entitlements.rememberedPantryCap
            _ = try pantryRepo.upsertFromScan(
                scanInputs,
                on: household,
                usedRemembered: usedRemembered,
                cap: cap,
            )
        } catch {
            Logger.scanFeature.error("upsertFromScan failed: \(error.localizedDescription, privacy: .public)")
            // Continue despite persistence failure — the solve call doesn't
            // depend on CloudKit round-trip completing.
        }

        phase = .confirmed
        let lite = ingredients.map { ing in
            DinnerSolveRequest.IngredientLite(
                displayName: ing.displayName,
                canonicalSlug: ing.canonicalSlug,
                amountText: ing.amountText,
            )
        }
        return ConfirmedScanResult(ingredients: lite, parseID: parseID)
    }

    func resetToPrimer() {
        phase = .idle
        ingredients = []
        parseID = nil
        lastLatencyMS = nil
        overallConfidence = nil
        capturedImageData = nil
    }

    #if DEBUG
    /// Test-only: seed the ingredient array and advance to review phase
    /// without a live Gemini call. Compiled out of Release builds.
    func __setIngredientsForTests(_ seeded: [Ingredient]) {
        self.ingredients = seeded
        self.phase = .review
    }
    #endif

    // MARK: - Helpers

    private func confidenceWeight(_ c: PantryParseResponse.PantryItemConfidence) -> Double {
        switch c {
        case .confirmed:    return 0.95
        case .needsReview:  return 0.55
        case .likelyStaple: return 0.70
        }
    }

    private func translate(_ c: PantryParseResponse.PantryItemConfidence) -> PantryItem.ParseConfidence {
        switch c {
        case .confirmed:    return .confirmed
        case .needsReview:  return .needsReview
        case .likelyStaple: return .likelyStaple
        }
    }

}

extension Logger {
    static let scanFeature = Logger(subsystem: "com.scalinity.stir", category: "ScanFeature")
}
