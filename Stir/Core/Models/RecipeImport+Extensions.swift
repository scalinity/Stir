// RecipeImport+Extensions
//
// Step-7 audit/correlation trail for every recipe import attempt
// (spec §4.10). Every URL paste, share-sheet import, screenshot OCR,
// and pasted-text attempt writes a row — successes link to a
// RecipePlan via `recipePlanId`; failures capture `errorCode` so the
// `recipe_import_completed` telemetry event has a persistent artifact
// to tie back to.
//
// Retention: hard delete 30 days after successful link to RecipePlan
// (CLAUDE.md §"Deferred" ASSUMPTION: 30d window matches spec §4.10's
// "retention window passes"; codified here and surfaced in the repo's
// `purgeExpired(olderThan:)` entry point).
//
// CloudKit syncable via NSPersistentCloudKitContainer (same rules as
// step-2 baseline: no unique constraints; all attributes optional at
// schema layer; required-ness enforced by the repository + typed
// enums below).

import Foundation

// MARK: - Typed enums (persisted as String for CloudKit-safety)

/// `sourceType` — discriminates the four entry points. Kept distinct
/// so `recipe_import_started` / `recipe_import_completed` telemetry
/// can funnel-analyze Safari-share vs manual URL paste. Codable
/// conformance lets the wire-format AIDispatch DTOs embed it directly.
public enum RecipeImportSource: String, Codable, Sendable, CaseIterable {
    case url = "url"
    case shareSheet = "share_sheet"
    case screenshotOCR = "screenshot_ocr"
    case pastedText = "pasted_text"
}

/// `status` — lifecycle from insertion through Gemini call to either
/// RecipePlan link-up or error record.
public enum RecipeImportStatus: String, Sendable, CaseIterable {
    case pending   = "pending"
    case processing = "processing"
    case completed = "completed"
    case failed    = "failed"
}

/// User-cancelled errorCode sentinel — distinct from `IMPORT-01` so
/// the Saved tab's "recent imports" surface can distinguish "user
/// backed out of Import Review" from "AI couldn't parse". Paired with
/// `status = .failed` so the RecipeImport row still exists as a trail
/// (vs being silently dropped).
public enum RecipeImportErrorCode {
    public static let userCancelled = "USER_CANCELLED"
    public static let importFailed = "IMPORT-01"
}

// MARK: - Typed accessors

public extension RecipeImport {
    /// Typed read; unknown values (e.g. a future `rss_feed` source) fall
    /// back to `.url` as the closest safe bucket. Write via `sourceType`
    /// raw string OR via `setSource(_:)` for type-checked writes.
    var source: RecipeImportSource {
        RecipeImportSource(rawValue: sourceType ?? "") ?? .url
    }

    /// Typed read; unknown values fall back to `.pending` so a corrupted
    /// row doesn't accidentally advertise as completed.
    var statusEnum: RecipeImportStatus {
        RecipeImportStatus(rawValue: status ?? "") ?? .pending
    }

    /// Whether this row's retention window has elapsed. Purged by
    /// `RecipeImportRepository.purgeExpired(olderThan:now:)`.
    func isExpired(olderThan days: Int, now: Date = Date()) -> Bool {
        guard statusEnum == .completed, let completedAt else { return false }
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        return completedAt < cutoff
    }

    /// Convenience: set source with type safety.
    func setSource(_ value: RecipeImportSource) {
        self.sourceType = value.rawValue
    }

    /// Convenience: set status with type safety.
    func setStatus(_ value: RecipeImportStatus) {
        self.status = value.rawValue
    }
}
