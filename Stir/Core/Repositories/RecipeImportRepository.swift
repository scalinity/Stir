// RecipeImportRepository
//
// Step-7 audit/correlation trail. Every recipe import attempt —
// success, failure, or user cancellation — writes a row (spec §4.10).
// The row is the source of truth for `recipe_import_completed`
// telemetry; iOS emits the event using this row's `source`, the
// review screen's `edit_required` signal, and the parsed recipe's
// `parse_quality`.
//
// State machine (enforced here, not at Core Data layer):
//   new row                    → status=.pending, submittedAt=now
//   AIDispatch dispatched      → status=.processing (optional)
//   successful parse + persist → status=.completed, completedAt=now,
//                                recipePlanId populated
//   Gemini failure             → status=.failed, errorCode=IMPORT-01
//   user cancelled on review   → status=.failed, errorCode=USER_CANCELLED
//
// CLAUDE.md §"Executing actions with care" — never delete a row that
// was successfully linked to a RecipePlan until `purgeExpired(...)`
// has fired (30d retention).

import CoreData
import CryptoKit
import Foundation

@MainActor
final class RecipeImportRepository {
    private let controller: PersistenceController

    init(controller: PersistenceController = .shared) {
        self.controller = controller
    }

    struct StartInput: Sendable {
        let importID: UUID
        let source: RecipeImportSource
        let sourceURL: String?
        let ocrPageCount: Int16
        let rawContent: String   // hashed, not stored verbatim
    }

    /// Insert a pending RecipeImport row. Returns the persisted entity.
    /// `rawContent` is hashed (SHA-256 hex) into `rawTextHash`; the raw
    /// bytes are not retained — only the hash, for dedupe + audit.
    @discardableResult
    func start(for household: HouseholdProfile, input: StartInput) throws -> RecipeImport {
        let context = controller.viewContext
        let row = RecipeImport(context: context)
        row.id = input.importID
        row.household = household
        row.setSource(input.source)
        row.sourceURL = input.sourceURL
        row.ocrPageCount = input.ocrPageCount
        row.rawTextHash = Self.sha256Hex(input.rawContent)
        row.setStatus(.pending)
        row.submittedAt = Date()
        try controller.save()
        return row
    }

    /// Insert a row that's ALREADY failed — for client-side rejections
    /// (empty URL, bad scheme, OCR decode failure) where the attempt
    /// never reached the backend. Single save: previously start +
    /// markFailed was two transactions and a throw on the second left
    /// orphaned `.pending` rows with no error code (CA1-13).
    @discardableResult
    func recordClientReject(
        for household: HouseholdProfile,
        input: StartInput,
        errorCode: String,
    ) throws -> RecipeImport {
        let context = controller.viewContext
        let row = RecipeImport(context: context)
        row.id = input.importID
        row.household = household
        row.setSource(input.source)
        row.sourceURL = input.sourceURL
        row.ocrPageCount = input.ocrPageCount
        row.rawTextHash = Self.sha256Hex(input.rawContent)
        row.setStatus(.failed)
        row.submittedAt = Date()
        row.completedAt = Date()
        row.errorCode = errorCode
        try controller.save()
        return row
    }

    /// Mark the row as in-flight. Optional but useful when the Edge
    /// Function returns status='queued' (async path) so the UI can
    /// show an "importing…" state.
    func markProcessing(_ row: RecipeImport) throws {
        row.setStatus(.processing)
        try controller.save()
    }

    /// Mark the row as successfully completed and link to the RecipePlan
    /// that was just created from the parsed result. `aiRequestID`
    /// correlates with `ai_request_log.request_id` on the backend.
    func markCompleted(
        _ row: RecipeImport,
        recipePlanID: UUID,
        aiRequestID: String?,
    ) throws {
        row.setStatus(.completed)
        row.completedAt = Date()
        row.recipePlanId = recipePlanID
        row.aiRequestId = aiRequestID
        try controller.save()
    }

    /// Mark the row as failed with a typed error code. Errors flow here:
    ///   - USER_CANCELLED (user backed out of Import Review)
    ///   - IMPORT-01 (Gemini parse failure / unparseable source)
    ///   - RATE-01 (quota exhausted — surface paywall, still persist row)
    func markFailed(_ row: RecipeImport, errorCode: String) throws {
        row.setStatus(.failed)
        row.completedAt = Date()
        row.errorCode = errorCode
        try controller.save()
    }

    /// Look up by import_id (the client-generated UUID used as idempotency
    /// key on the Edge Function). Returns nil if not present.
    func find(importID: UUID) throws -> RecipeImport? {
        let fetch: NSFetchRequest<RecipeImport> = NSFetchRequest(entityName: "RecipeImport")
        fetch.predicate = NSPredicate(format: "id == %@", importID as CVarArg)
        fetch.fetchLimit = 1
        return try controller.viewContext.fetch(fetch).first
    }

    /// Recent imports for the Saved tab's "recent activity" section.
    /// Sort: submittedAt desc. Limit defaults to 25.
    func recent(for household: HouseholdProfile, limit: Int = 25) throws -> [RecipeImport] {
        let fetch: NSFetchRequest<RecipeImport> = NSFetchRequest(entityName: "RecipeImport")
        fetch.predicate = NSPredicate(format: "household == %@", household)
        fetch.sortDescriptors = [NSSortDescriptor(key: "submittedAt", ascending: false)]
        fetch.fetchLimit = limit
        return try controller.viewContext.fetch(fetch)
    }

    /// Hard-delete completed RecipeImport rows whose `completedAt` is
    /// older than the retention window. Safe to run from a periodic
    /// task at app launch; idempotent.
    @discardableResult
    func purgeExpired(olderThan days: Int = 30, now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        let fetch: NSFetchRequest<RecipeImport> = NSFetchRequest(entityName: "RecipeImport")
        fetch.predicate = NSPredicate(
            format: "status == %@ AND completedAt < %@",
            RecipeImportStatus.completed.rawValue,
            cutoff as NSDate,
        )
        let rows = try controller.viewContext.fetch(fetch)
        for row in rows { controller.viewContext.delete(row) }
        if !rows.isEmpty { try controller.save() }
        return rows.count
    }

    // MARK: - Hash helper

    /// SHA-256 hex digest for the rawTextHash field. UTF-8 bytes only
    /// so different encodings produce the same hash.
    static func sha256Hex(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
