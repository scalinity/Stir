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

    /// One captured photo in the in-flow accumulator. SCA-35 multi-image
    /// scan accepts up to `maxImagesPerScan` photos before submission.
    /// `data` is the compressed JPEG bytes ready for wire submission;
    /// `mimeType` is "image/jpeg" today but the field future-proofs for
    /// PNG/HEIC paths if Apple's HEIF compression flips back on.
    struct CapturedImage: Identifiable, Sendable, Equatable {
        let id: UUID
        let data: Data
        let mimeType: String

        init(id: UUID = UUID(), data: Data, mimeType: String) {
            self.id = id
            self.data = data
            self.mimeType = mimeType
        }
    }

    /// Outcome of `appendCapturedImage`. View consumes this to decide
    /// whether to keep the live preview (success), bounce silently
    /// (already capped), or stand back (paywall presented).
    enum AppendResult: Equatable, Sendable {
        case appended
        case capped
        case blockedByEntitlement
    }

    /// Hard ceiling on photos per scan. Mirrors the backend Zod cap
    /// (`PANTRY_PARSE_MULTI_IMAGE_MAX = 4`) and the cost-economics call
    /// in SCA-35 — covers fridge + 2 pantry shelves + counter without
    /// pushing per-scan Gemini cost into a problematic range.
    static let maxImagesPerScan = PantryParseRequest.multiImageMax

    private(set) var phase: Phase = .idle
    private(set) var ingredients: [Ingredient] = []
    private(set) var parseID: UUID?
    private(set) var lastLatencyMS: Int?
    private(set) var overallConfidence: Double?
    /// Compressed JPEGs accumulated in the capture phase. The first
    /// element is the "primary" thumbnail rendered in review; the
    /// review header may also render the rest as a strip when count >
    /// 1. Cleared on `resetToPrimer`.
    private(set) var capturedImages: [CapturedImage] = []

    /// Back-compat thumbnail accessor used by the review header.
    var primaryCapturedImageData: Data? { capturedImages.first?.data }

    private let aiDispatch: AIDispatch
    private let pantryRepo: PantryItemRepository
    private let householdStore: CurrentHouseholdStore
    private let entitlements: EntitlementService
    /// Injected by ScanFlowRoot so the VM can present the multi-image
    /// scan paywall when a non-Pro user attempts a 2nd photo. Optional
    /// because tests construct the VM without a paywall surface.
    private let presentPaywall: (@MainActor (PaywallTrigger) -> Void)?

    init(
        aiDispatch: AIDispatch,
        pantryRepo: PantryItemRepository,
        householdStore: CurrentHouseholdStore,
        entitlements: EntitlementService,
        presentPaywall: (@MainActor (PaywallTrigger) -> Void)? = nil,
    ) {
        self.aiDispatch = aiDispatch
        self.pantryRepo = pantryRepo
        self.householdStore = householdStore
        self.entitlements = entitlements
        self.presentPaywall = presentPaywall
    }

    // MARK: - Phase transitions

    func enterCapturing() {
        phase = .capturing
    }

    /// Append a captured photo to the in-flow accumulator (SCA-35).
    ///
    /// Cap-precedes-entitlement is intentional: at the maximum photo
    /// count the action is genuinely unavailable (no upgrade path
    /// helps), so we surface `.capped` without firing a paywall. Only
    /// when capacity exists AND the user is non-Pro on a 2nd+ shot does
    /// the gate fire — the paywall is reserved for "you could pay to
    /// unlock this," never for "you've already done the maximum." This
    /// also preserves the invariant that the paywall fires only on a
    /// new attempted action, never on already-accumulated buffer state.
    ///
    /// Returns:
    ///   - `.appended` — photo was added; caller can render the new
    ///     thumbnail and restart the live preview for another shot.
    ///   - `.capped` — already at `maxImagesPerScan`. Caller should
    ///     keep the shutter disabled and surface the cap message.
    ///   - `.blockedByEntitlement` — caller is non-Pro and is trying
    ///     to add a 2nd+ photo. The paywall is fired via the injected
    ///     `presentPaywall` handler before this returns; the caller
    ///     should bail back to live preview without appending.
    @discardableResult
    func appendCapturedImage(_ data: Data, mimeType: String) -> AppendResult {
        if capturedImages.count >= Self.maxImagesPerScan {
            // SCA-36 S11: defensive breadcrumb. Shutter should be disabled
            // before this fires; if it does, a SwiftUI re-render race
            // happened between buffer mutation and view diffing.
            Logger.scanFeature.warning("appendCapturedImage hit cap — shutter race?")
            return .capped
        }
        // First photo is unmetered for every tier — multi-image is what
        // costs more on Gemini. The paywall fires only when the user
        // tries to add a 2nd+ photo.
        if !capturedImages.isEmpty,
           entitlements.canAccess(.multiImageScan) != .allowed
        {
            presentPaywall?(.multiImageScanGate)
            return .blockedByEntitlement
        }
        capturedImages.append(CapturedImage(data: data, mimeType: mimeType))
        return .appended
    }

    /// True if a new shutter tap would land cleanly. Used by the capture
    /// view to pre-check at the shutter site BEFORE running the
    /// ~500ms freeze→stop→restart cycle, so a non-Pro user attempting
    /// a 2nd shot doesn't watch the camera spin up only to land on a
    /// paywall (SCA-36 W5).
    ///
    /// This DOES NOT mutate state and DOES NOT fire the paywall —
    /// callers that get `.blockedByEntitlement` should call
    /// `firePaywallForMultiImageGate()` to surface the trigger.
    func canAppendCapturedImage() -> AppendResult {
        if capturedImages.count >= Self.maxImagesPerScan {
            return .capped
        }
        if !capturedImages.isEmpty,
           entitlements.canAccess(.multiImageScan) != .allowed
        {
            return .blockedByEntitlement
        }
        return .appended
    }

    /// Fire the multi-image-scan paywall trigger via the injected
    /// presenter. Used by the capture view's pre-shutter gate (W5).
    func firePaywallForMultiImageGate() {
        presentPaywall?(.multiImageScanGate)
    }

    /// Remove a captured photo by id. Used by the thumbnail strip's
    /// per-photo delete affordance.
    func removeCapturedImage(id: UUID) {
        let prior = capturedImages.count
        capturedImages.removeAll { $0.id == id }
        if capturedImages.count == prior {
            // SCA-36 S20-companion: log if a phantom-tap fires (e.g.
            // SwiftUI re-render lag between buffer mutation and view
            // diffing). No-op functionally; observability only.
            Logger.scanFeature.debug("removeCapturedImage: id not found in buffer")
        }
    }

    /// Drop accumulated captures without resetting parse outputs. Used
    /// by the capture view to start a fresh scan when the user re-
    /// enters the capture screen via swipe-back (SCA-36 C2).
    func clearCapturedImages() {
        capturedImages.removeAll()
    }

    /// Submit the accumulated captures for AI parsing. Routes to the
    /// singular wire shape when count == 1 (back-compat path used by
    /// every Free/Premium scan and Pro single-photo scan), and to the
    /// plural wire shape when count >= 2 (Pro multi-image).
    func submitCapturedImages() async {
        guard !capturedImages.isEmpty else {
            Logger.scanFeature.warning("submitCapturedImages called with empty buffer — dropping")
            return
        }
        phase = .parsing
        let clientRequestID = UUID()
        let imageCount = capturedImages.count
        let totalBytes = capturedImages.reduce(0) { $0 + $1.data.count }

        PostHogClient.shared.capture(.scanSubmitted, properties: [
            "client_request_id": clientRequestID.uuidString,
            "image_count": imageCount,
            "image_bytes": totalBytes,
        ])

        do {
            let started = Date()
            let response: PantryParseResponse
            if imageCount == 1 {
                let primary = capturedImages[0]
                response = try await aiDispatch.pantryParse(
                    clientRequestID: clientRequestID,
                    imageData: primary.data,
                    mimeType: primary.mimeType,
                    // TODO(step-4): compute household hash so cache invalidates
                    // when DietaryRule/KitchenEquipment changes mid-session.
                    householdProfileHash: nil,
                )
            } else {
                response = try await aiDispatch.pantryParseMulti(
                    clientRequestID: clientRequestID,
                    images: capturedImages.map { ($0.data, $0.mimeType) },
                    householdProfileHash: nil,
                )
            }
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
                "image_count": imageCount,
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
            // SCA-36 S6: surface VAL-01 with image-specific copy when
            // we have multi-image context — the field path on the wire
            // (e.g. images[2].base64) tells us a specific photo failed.
            // We don't parse the field path here (the wire shape isn't
            // exposed through StirError), but bias the copy toward
            // "retake" framing for multi-image submits where one bad
            // photo is the most likely cause.
            let errorCopy = imageCount > 1
                ? "We couldn't process one of your photos. Try retaking the affected angle."
                : "Something went wrong scanning. Try again."
            self.phase = .error(message: errorCopy, recoverable: false)
            Logger.scanFeature.error("VAL-01 on pantry-parse: \(message, privacy: .public)")
        } catch {
            // SCA-36 C1: bail without flipping phase or emitting NET-01
            // telemetry when the view was dismissed mid-submit.
            // URLSession surfaces this as URLError(.cancelled) on iOS;
            // the swift-concurrency layer surfaces it as
            // CancellationError. Either way `Task.isCancelled` is true.
            if Task.isCancelled {
                Logger.scanFeature.debug("submitCapturedImages cancelled mid-flight")
                return
            }
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
        capturedImages = []
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
