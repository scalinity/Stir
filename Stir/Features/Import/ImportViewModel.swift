// ImportViewModel
//
// Drives the step-7 recipe import flow — URL / pasted text / screenshot
// OCR. Every attempt writes a RecipeImport row (audit trail per spec
// §4.10); successful parses also persist a RecipePlan + ingredients +
// steps so the recipe lands in Saved.
//
// Stage machine:
//   .idle → .submitting → (.review | .queued | .error)
//   .review → .saving → .saved | .error
//
// Telemetry (spec §15 canonical):
//   recipe_import_started   {source_type}
//   recipe_import_completed {source_type, parse_quality, edit_required}
//
// `edit_required` flips true if the user tapped any edit affordance on
// the review screen before saving. For v1 review is read-only so the
// flag always starts false; a future commit adds inline editing.

import CoreData
import Foundation
import OSLog
import UIKit

@Observable
@MainActor
final class ImportViewModel {
    /// Intentionally NOT Equatable — `RecipeImportResponse.ImportedRecipe`
    /// is a Decodable payload without Equatable conformance. Views pattern-
    /// match on the case; callers that need "is this stage X" use the
    /// boolean helpers below or the `kind` accessor for tests.
    enum Stage {
        case idle
        case submitting
        case review(recipe: RecipeImportResponse.ImportedRecipe, parseQuality: String)
        case queued(jobID: String)
        case saving
        case saved(recipePlanID: UUID)
        case error(code: String, message: String)
    }

    /// Coarse identifier for tests — associated-value-free variant of
    /// `Stage`. Production code pattern-matches on `stage` directly.
    enum StageKind: String, Equatable, CaseIterable {
        case idle, submitting, review, queued, saving, saved, error
    }

    private(set) var stage: Stage = .idle

    var stageKind: StageKind {
        switch stage {
        case .idle: return .idle
        case .submitting: return .submitting
        case .review: return .review
        case .queued: return .queued
        case .saving: return .saving
        case .saved: return .saved
        case .error: return .error
        }
    }

    var isBusy: Bool {
        switch stage {
        case .submitting, .saving: return true
        default: return false
        }
    }

    var isReviewing: Bool {
        if case .review = stage { return true }
        return false
    }

    /// Source the current attempt used — captured for telemetry on
    /// completion.
    private var activeSource: RecipeImportSource = .url

    /// Audit row created at submit time; mutated through markProcessing/
    /// markCompleted/markFailed as the flow progresses.
    private var activeImportRow: RecipeImport?

    /// Whether the user edited anything on the review screen. Plumbed
    /// through to the `edit_required` property when we persist.
    var didEdit: Bool = false

    let household: HouseholdProfile

    private let aiDispatch: AIDispatch
    private let importRepo: RecipeImportRepository
    private let controller: PersistenceController
    private let analytics: PostHogClient
    private let ocrService: OCRService

    init(
        household: HouseholdProfile,
        aiDispatch: AIDispatch,
        importRepo: RecipeImportRepository = RecipeImportRepository(),
        controller: PersistenceController = .shared,
        analytics: PostHogClient = .shared,
        ocrService: OCRService = OCRService(),
    ) {
        self.household = household
        self.aiDispatch = aiDispatch
        self.importRepo = importRepo
        self.controller = controller
        self.analytics = analytics
        self.ocrService = ocrService
    }

    // MARK: - URL import

    /// Submit a URL for parsing. Validates scheme (http/https) client-
    /// side; backend does the deeper validation + fetch.
    func submitURL(_ urlString: String) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            await recordClientRejection(
                source: .url,
                rawContent: trimmed.isEmpty ? "(empty)" : trimmed,
                message: "That doesn't look like a web address.",
            )
            return
        }
        await submit(
            source: .url,
            payload: .url(url.absoluteString),
            rawContent: url.absoluteString,
            sourceURL: url.absoluteString,
        )
    }

    /// Submit typed-in recipe text.
    func submitPastedText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await recordClientRejection(
                source: .pastedText,
                rawContent: "(empty)",
                message: "Paste some recipe text first.",
            )
            return
        }
        await submit(
            source: .pastedText,
            payload: .pastedText(trimmed),
            rawContent: trimmed,
            sourceURL: nil,
        )
    }

    /// OCR a screenshot then submit the extracted text.
    func submitScreenshot(image: UIImage) async {
        stage = .submitting
        let ocrResult: OCRService.Result
        do {
            ocrResult = try await ocrService.recognizeText(in: image)
        } catch let error as OCRService.Failure {
            await recordClientRejection(
                source: .screenshotOCR,
                rawContent: "(ocr-failed)",
                message: error.errorDescription ?? "OCR failed.",
                errorCode: "IMPORT-01",
            )
            return
        } catch {
            await recordClientRejection(
                source: .screenshotOCR,
                rawContent: "(ocr-failed)",
                message: error.localizedDescription,
                errorCode: "IMPORT-01",
            )
            return
        }
        await submit(
            source: .screenshotOCR,
            payload: .screenshotOCR(text: ocrResult.text, pageCount: ocrResult.pageCount),
            rawContent: ocrResult.text,
            sourceURL: nil,
            ocrPageCount: Int16(ocrResult.pageCount),
        )
    }

    // MARK: - Client-rejected attempt

    /// Persist a failed RecipeImport row for an attempt that never reached
    /// the backend (empty URL, bad scheme, OCR decode failure). Spec §4.10
    /// invariant: "every import attempt persists a RecipeImport row".
    /// errorCode defaults to VAL-01 for input validation rejections;
    /// OCR-path failures pass IMPORT-01.
    private func recordClientRejection(
        source: RecipeImportSource,
        rawContent: String,
        message: String,
        errorCode: String = "VAL-01",
    ) async {
        activeSource = source
        let input = RecipeImportRepository.StartInput(
            importID: UUID(),
            source: source,
            sourceURL: source == .url ? rawContent : nil,
            ocrPageCount: 0,
            rawContent: rawContent,
        )
        do {
            let row = try importRepo.start(for: household, input: input)
            try importRepo.markFailed(row, errorCode: errorCode)
            activeImportRow = row
        } catch {
            Logger.ui.warning("import client-reject audit write failed: \(error.localizedDescription, privacy: .public)")
        }
        stage = .error(code: errorCode, message: message)
    }

    // MARK: - Shared submit path

    private func submit(
        source: RecipeImportSource,
        payload: RecipeImportRequest.Payload,
        rawContent: String,
        sourceURL: String?,
        ocrPageCount: Int16 = 0,
    ) async {
        activeSource = source
        stage = .submitting

        let importID = UUID()
        let input = RecipeImportRepository.StartInput(
            importID: importID,
            source: source,
            sourceURL: sourceURL,
            ocrPageCount: ocrPageCount,
            rawContent: rawContent,
        )
        let importRow: RecipeImport
        do {
            importRow = try importRepo.start(for: household, input: input)
        } catch {
            Logger.ui.error("import audit row create failed: \(error.localizedDescription, privacy: .public)")
            stage = .error(code: "VAL-01", message: "Couldn't start the import.")
            return
        }
        activeImportRow = importRow

        analytics.capture(
            .recipeImportStarted,
            properties: StepSevenTelemetry.recipeImportStarted(source: source),
        )

        do { try importRepo.markProcessing(importRow) } catch {
            Logger.ui.warning("markProcessing failed: \(error.localizedDescription, privacy: .public)")
        }

        // Call the Edge Function.
        let request = RecipeImportRequest(
            importID: importID,
            sourceType: source,
            payload: payload,
        )
        do {
            let response = try await aiDispatch.recipeImport(request: request)
            switch response.status {
            case .completed:
                guard let recipe = response.recipe else {
                    stage = .error(code: "IMPORT-01", message: "The import came back empty.")
                    markFailed(importRow, errorCode: "IMPORT-01")
                    return
                }
                stage = .review(recipe: recipe, parseQuality: recipe.parseQuality.rawValue)
            case .queued:
                stage = .queued(jobID: response.asyncJobID ?? importID.uuidString)
            }
        } catch {
            Logger.ui.error("recipe import failed: \(error.localizedDescription, privacy: .public)")
            stage = .error(code: "IMPORT-01", message: "We couldn't read that recipe. Try again or paste the text.")
            markFailed(importRow, errorCode: "IMPORT-01")
        }
    }

    // MARK: - Review → persist

    /// Commit the reviewed recipe to Core Data as a RecipePlan.
    func confirmAndSave() async {
        guard case .review(let recipe, let quality) = stage else { return }
        guard let importRow = activeImportRow else { return }
        stage = .saving

        do {
            let planID = try persistRecipePlan(recipe, source: activeSource)
            try importRepo.markCompleted(
                importRow,
                recipePlanID: planID,
                aiRequestID: nil,
            )
            analytics.capture(
                .recipeImportCompleted,
                properties: StepSevenTelemetry.recipeImportCompleted(
                    source: activeSource,
                    parseQuality: quality,
                    editRequired: didEdit,
                ),
            )
            stage = .saved(recipePlanID: planID)
        } catch {
            Logger.ui.error("import save failed: \(error.localizedDescription, privacy: .public)")
            stage = .error(code: "IMPORT-01", message: "Couldn't save. Try again.")
        }
    }

    /// User cancelled the import on the review screen. Writes the audit
    /// row as failed with USER_CANCELLED errorCode (CLAUDE.md default).
    func cancelImport() {
        if let importRow = activeImportRow {
            do {
                try importRepo.markFailed(importRow, errorCode: RecipeImportErrorCode.userCancelled)
            } catch {
                Logger.ui.warning("markFailed on cancel: \(error.localizedDescription, privacy: .public)")
            }
        }
        stage = .idle
    }

    // MARK: - Private

    private func markFailed(_ importRow: RecipeImport, errorCode: String) {
        do {
            try importRepo.markFailed(importRow, errorCode: errorCode)
        } catch {
            Logger.ui.warning("markFailed write: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Persist the parsed recipe as a RecipePlan + RecipeIngredient +
    /// RecipeStep rows. Sets `household` so the new plan shows up in
    /// `CookingSessionRepository.savedMealEntries` (which filters on
    /// household). Caution tags + isOptional flags are deferred (v1
    /// import doesn't extract those; Saved detail view can add later).
    private func persistRecipePlan(
        _ recipe: RecipeImportResponse.ImportedRecipe,
        source: RecipeImportSource,
    ) throws -> UUID {
        let ctx = controller.viewContext
        let plan = RecipePlan(context: ctx)
        let planID = UUID()
        plan.id = planID
        plan.household = household
        plan.title = recipe.title
        plan.servings = Int16(recipe.servings ?? 2)
        plan.estimatedMinutes = Int16(recipe.estimatedMinutes ?? 30)
        plan.createdAt = Date()
        plan.isFavorite = false
        plan.aiVersion = "recipe_import_v1"
        for (idx, ing) in recipe.ingredients.enumerated() {
            let row = RecipeIngredient(context: ctx)
            row.id = UUID()
            row.recipePlan = plan
            row.displayName = ing.displayName
            row.canonicalIngredientSlug = ing.canonicalSlug
            row.amountText = ing.amountText
            row.sortOrder = Int16(idx)
        }
        for step in recipe.steps {
            let row = RecipeStep(context: ctx)
            row.id = UUID()
            row.recipePlan = plan
            row.stepNumber = Int16(step.stepNumber)
            row.instructionText = step.instructionText
            row.timerSeconds = Int32(step.timerSeconds ?? 0)
        }
        _ = source  // reserved for step-8 source_type telemetry on RecipePlan
        try ctx.save()
        return planID
    }
}
