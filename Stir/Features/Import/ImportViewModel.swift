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
            ocrPageCount: Int16(clamping: ocrResult.pageCount),
        )
    }

    // MARK: - Client-rejected attempt

    /// Persist a failed RecipeImport row for an attempt that never reached
    /// the backend (empty URL, bad scheme, OCR decode failure). Spec §4.10
    /// invariant: "every import attempt persists a RecipeImport row".
    /// errorCode defaults to VAL-01 for input validation rejections;
    /// OCR-path failures pass IMPORT-01.
    ///
    /// Emits recipe_import_completed with parseQuality="failed" so the
    /// import-quality funnel (spec §15) sees client-side rejections
    /// alongside server failures. Uses repo.recordClientReject for a
    /// single-save insert — previously start + markFailed was two saves
    /// and a throw on the second left orphaned `.pending` rows (CA1-13).
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
            let row = try importRepo.recordClientReject(
                for: household,
                input: input,
                errorCode: errorCode,
            )
            activeImportRow = row
        } catch {
            Logger.ui.warning("import client-reject audit write failed: \(error.localizedDescription, privacy: .public)")
        }
        analytics.capture(
            .recipeImportCompleted,
            properties: StepSevenTelemetry.recipeImportCompleted(
                source: source,
                parseQuality: "failed",
                editRequired: false,
            ),
        )
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
            // No audit row exists to mark failed — emit completed so the
            // funnel still sees the failure. source_type is captured at
            // activeSource assignment above.
            emitImportCompleted(parseQuality: "failed")
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
                    emitImportCompleted(parseQuality: "failed")
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
            emitImportCompleted(parseQuality: "failed")
        }
    }

    // MARK: - Review → persist

    /// Commit the reviewed recipe to Core Data as a RecipePlan.
    ///
    /// Writes RecipePlan + ingredients + steps AND audit-row completion
    /// state in a SINGLE controller.save() call. Previously persistRecipePlan
    /// saved internally and markCompleted saved again — if the second save
    /// threw, the plan was already in Saved but the audit row sat at
    /// `.processing` forever (CA1-13). The catch branch now calls
    /// markFailed so the audit row finalizes with IMPORT-01, and emits
    /// recipe_import_completed so the funnel sees the failure.
    func confirmAndSave() async {
        guard case .review(let recipe, let quality) = stage else { return }
        guard let importRow = activeImportRow else { return }
        stage = .saving

        do {
            let planID = try buildRecipePlan(recipe, source: activeSource)
            // Set audit completion fields on the same viewContext so the
            // save below is a single atomic write.
            importRow.setStatus(.completed)
            importRow.completedAt = Date()
            importRow.recipePlanId = planID
            importRow.aiRequestId = nil
            try controller.save()
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
            markFailed(importRow, errorCode: "IMPORT-01")
            emitImportCompleted(parseQuality: "failed")
        }
    }

    /// User cancelled the import on the review screen. Writes the audit
    /// row as failed with USER_CANCELLED errorCode (CLAUDE.md default) —
    /// unless the row is ALREADY `.failed`, in which case we leave the
    /// prior errorCode intact (overwriting e.g. IMPORT-01 with
    /// USER_CANCELLED would corrupt the audit trail on retry-after-error).
    /// Emits recipe_import_completed with parseQuality="user_cancelled"
    /// so the import funnel sees backouts (spec §15).
    func cancelImport() {
        if let importRow = activeImportRow, importRow.statusEnum != .failed {
            do {
                try importRepo.markFailed(importRow, errorCode: RecipeImportErrorCode.userCancelled)
            } catch {
                Logger.ui.warning("markFailed on cancel: \(error.localizedDescription, privacy: .public)")
            }
        }
        emitImportCompleted(parseQuality: "user_cancelled")
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

    /// Emit recipe_import_completed using the currently-active source.
    /// Centralized so cancel/fail paths don't duplicate the StepSevenTelemetry
    /// call shape — single edit-site if the property bag grows.
    private func emitImportCompleted(parseQuality: String) {
        analytics.capture(
            .recipeImportCompleted,
            properties: StepSevenTelemetry.recipeImportCompleted(
                source: activeSource,
                parseQuality: parseQuality,
                editRequired: didEdit,
            ),
        )
    }

    /// Build RecipePlan + RecipeIngredient + RecipeStep entities on the
    /// viewContext WITHOUT saving. Caller pairs this with an audit-row
    /// update and a single controller.save() so the persist + audit-
    /// completion state land atomically. Caution tags + isOptional flags
    /// are deferred (v1 import doesn't extract those; Saved detail view
    /// can add later).
    private func buildRecipePlan(
        _ recipe: RecipeImportResponse.ImportedRecipe,
        source: RecipeImportSource,
    ) throws -> UUID {
        let ctx = controller.viewContext
        let plan = RecipePlan(context: ctx)
        let planID = UUID()
        plan.id = planID
        plan.household = household
        plan.title = recipe.title
        plan.servings = Int16(clamping: recipe.servings ?? 2)
        plan.estimatedMinutes = Int16(clamping: recipe.estimatedMinutes ?? 30)
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
            row.sortOrder = Int16(clamping: idx)
        }
        for step in recipe.steps {
            let row = RecipeStep(context: ctx)
            row.id = UUID()
            row.recipePlan = plan
            row.stepNumber = Int16(clamping: step.stepNumber)
            row.instructionText = step.instructionText
            row.timerSeconds = Int32(clamping: step.timerSeconds ?? 0)
        }
        _ = source  // reserved for step-8 source_type telemetry on RecipePlan
        return planID
    }
}
