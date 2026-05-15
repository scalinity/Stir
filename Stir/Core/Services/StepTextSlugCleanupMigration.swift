// StepTextSlugCleanupMigration
//
// SCA-430 — one-shot per-install scan over RecipeStep.instructionText
// rows in Core Data, replacing legacy `KitchenEquipment.CommonCode`
// rawValue slugs (e.g. `food_processor`, `air_fryer`) with their
// lowercased displayName form (e.g. `food processor`, `air fryer`).
//
// Backstory: SCA-423 fixed the SOURCE of slug leakage — the four AI
// prompt-render sites now convert through a backend display-name
// mirror before injecting `available_equipment` into the system
// instruction. But Step.instructionText rows generated BEFORE that
// deploy still carry the raw slug verbatim. CloudKit is the source of
// truth for user content (north-star constraint #3); the backend has
// no reach into a user's private DB, so the cleanup must run on-
// device. Each device runs the migration once, writes to its local
// Core Data, and NSPersistentCloudKitContainer propagates to the
// private CloudKit zone on its own cadence.
//
// Scope filter — only the 10 multi-token slugs participate:
// `food_processor`, `air_fryer`, `instant_pot`, `slow_cooker`,
// `stand_mixer`, `rice_cooker`, `cast_iron`, `nonstick_pan`,
// `sheet_pan`, `dutch_oven`. Single-token slugs like `oven`, `grill`,
// `blender`, `microwave`, `stovetop`, `griddle`, `skillet` are valid
// English words and would false-positive on natural recipe prose;
// the underscore-presence test (`code.rawValue.contains("_")`) is
// the gate. Slug values are word-boundary-matched
// (`\b<slug>\b`) so a hypothetical `non_food_processor` token would
// not match `food_processor` (Unicode `\b` treats `_` as a word
// character; the boundary check holds).
//
// Cadence: one-shot per install. UserDefaults flag
// `com.scalinity.stir.migrations.stepTextSlugCleanup.v1` is set after
// a successful pass. Reinstall (or `UserDefaults` wipe via a test
// seam) re-runs the work — same idempotent semantics. The migration
// is NOT tier-gated; legacy slug prose is a hygiene concern for
// every user regardless of entitlement.
//
// Errors LOGGED via OSLog, never thrown to the UI. The flag does NOT
// move on failure — the next foreground retries from scratch.
// Mirrors the `PantryTombstoneReaper` (SCA-97) safety posture.

import CoreData
import Foundation
import os

/// One-shot per-install migration that replaces legacy equipment slug
/// literals (e.g. `food_processor`) in `RecipeStep.instructionText`
/// with their display-name form (`food processor`). See file comment.
@MainActor
final class StepTextSlugCleanupMigration {
    /// UserDefaults key for the "did we run this already" flag.
    /// Namespaced under `com.scalinity.stir.*` mirroring
    /// `PantryTombstoneReaper.lastRunDefaultsKey`. The `.v1` suffix
    /// lets a future migration rev (e.g. a new slug vocabulary)
    /// re-run cleanly under a fresh key without colliding with this
    /// one.
    nonisolated static let didRunDefaultsKey = "com.scalinity.stir.migrations.stepTextSlugCleanup.v1"

    /// Memory-bounded faulting hint for the migration's fetch — the
    /// migration loads every RecipeStep into the bg context to read +
    /// optionally write `instructionText`. 100 is a conservative cap
    /// for a long-tail "I cook a lot" power user (~500 recipes × 5
    /// steps each = 2500 rows). Doesn't change save cadence; just
    /// caps how many faults fault in at once.
    nonisolated static let fetchBatchSize = 100

    /// Slugs whose displayName is a proper noun and must NOT be
    /// lowercased mid-sentence. "Dutch oven" and "Instant Pot" both
    /// remain capitalized regardless of position. The rest of the
    /// 10-slug vocabulary are common-noun phrases ("food processor",
    /// "slow cooker", …) and read naturally lowercased inside the
    /// surrounding step prose.
    nonisolated static let properNounSlugs: Set<String> = ["instant_pot", "dutch_oven"]

    private let controller: PersistenceController
    private let defaults: UserDefaults
    private let telemetry: @MainActor (_ stepsScanned: Int, _ stepsUpdated: Int) -> Void
    private let logger: Logger

    /// - Parameters:
    ///   - controller: the PersistenceController whose container the
    ///     migration writes through. The controller's
    ///     `performBackgroundTask` hop keeps fetches/saves off the
    ///     MainActor.
    ///   - defaults: UserDefaults — injectable for tests.
    ///   - telemetry: fired AFTER a successful run with the
    ///     `(steps_scanned, steps_updated)` counts. Default emits
    ///     `step_text_slug_cleanup_completed` to PostHog. Tests
    ///     inject a no-op or a collector.
    init(
        controller: PersistenceController,
        defaults: UserDefaults = .standard,
        telemetry: @MainActor @escaping (_ stepsScanned: Int, _ stepsUpdated: Int) -> Void = StepTextSlugCleanupMigration.defaultTelemetry,
    ) {
        self.controller = controller
        self.defaults = defaults
        self.telemetry = telemetry
        self.logger = Logger(subsystem: "com.scalinity.stir", category: "StepTextSlugCleanupMigration")
    }

    /// Foreground entry point. No-op when the flag is already set.
    /// On the first run, dispatches the scan onto a background
    /// NSManagedObjectContext, then sets the flag + emits telemetry
    /// from MainActor.
    ///
    /// - Returns: `(stepsScanned, stepsUpdated)` from this call, or
    ///   `nil` when the flag was already set (no work performed) or
    ///   the run errored.
    @discardableResult
    func runIfNeeded() async -> (stepsScanned: Int, stepsUpdated: Int)? {
        if defaults.bool(forKey: Self.didRunDefaultsKey) {
            return nil
        }

        let result: (Int, Int)
        do {
            result = try await performScan()
        } catch {
            logger.error(
                "step text slug cleanup failed: \(error.localizedDescription, privacy: .private)",
            )
            // Don't move the flag on failure — next foreground retries.
            return nil
        }

        defaults.set(true, forKey: Self.didRunDefaultsKey)
        telemetry(result.0, result.1)
        return (stepsScanned: result.0, stepsUpdated: result.1)
    }

    /// Test seam — wipe the gate flag so a second `runIfNeeded` call
    /// in the same test re-runs the work. Mirrors
    /// `PantryTombstoneReaper.reset()`.
    func reset() {
        defaults.removeObject(forKey: Self.didRunDefaultsKey)
    }

    /// Whether the migration has already completed for this install.
    var hasRun: Bool {
        defaults.bool(forKey: Self.didRunDefaultsKey)
    }

    // MARK: - Pure helper

    /// Replace any multi-token `KitchenEquipment.CommonCode` slug
    /// with its lowercased displayName form, anchored at word
    /// boundaries. Pure function — testable without a Core Data
    /// fixture. Returns the input unchanged when no slug matches.
    ///
    /// Slug filter: only slugs containing `_` participate. Single-
    /// token slugs (`oven`, `grill`, `blender`, `microwave`,
    /// `stovetop`, `griddle`, `skillet`) are valid English words
    /// and would false-positive on natural prose like "preheat the
    /// oven to 425". Verified zero false positives against the
    /// 17-case enum.
    nonisolated static func replaceEquipmentSlugs(in text: String) -> String {
        guard !text.isEmpty else { return text }
        var working = text
        for code in KitchenEquipment.CommonCode.allCases {
            let slug = code.rawValue
            guard slug.contains("_") else { continue }
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: slug))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(working.startIndex..<working.endIndex, in: working)
            let replacement = Self.properNounSlugs.contains(slug)
                ? code.displayName
                : code.displayName.lowercased()
            working = regex.stringByReplacingMatches(
                in: working,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement),
            )
        }
        return working
    }

    // MARK: - Bg scan

    /// Loads every RecipeStep on a background context, applies
    /// `replaceEquipmentSlugs` to each non-nil `instructionText`, and
    /// saves the context if any row changed. Returns `(scanned,
    /// updated)`. Hops back to the MainActor implicitly via the
    /// returning `await` — we don't touch any MainActor state inside
    /// the perform block.
    private func performScan() async throws -> (Int, Int) {
        let container = controller.container
        return try await withCheckedThrowingContinuation { continuation in
            container.performBackgroundTask { bg in
                do {
                    let request = NSFetchRequest<RecipeStep>(entityName: "RecipeStep")
                    request.fetchBatchSize = Self.fetchBatchSize
                    let rows = try bg.fetch(request)
                    var scanned = 0
                    var updated = 0
                    for row in rows {
                        scanned += 1
                        guard let original = row.instructionText, !original.isEmpty else { continue }
                        let rewritten = Self.replaceEquipmentSlugs(in: original)
                        if rewritten != original {
                            row.instructionText = rewritten
                            updated += 1
                        }
                    }
                    if bg.hasChanges {
                        try bg.save()
                    }
                    continuation.resume(returning: (scanned, updated))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Default telemetry

    /// Default emitter — fires `step_text_slug_cleanup_completed`
    /// with `steps_scanned` + `steps_updated`. Counts only; no
    /// instruction prose per ADR 0009's privacy invariant. Fires
    /// once per install (the flag prevents subsequent emissions);
    /// missing emissions across the install base flag either a
    /// wiring regression or a population that has no legacy slug
    /// prose.
    nonisolated static let defaultTelemetry: @MainActor (_ stepsScanned: Int, _ stepsUpdated: Int) -> Void = { stepsScanned, stepsUpdated in
        PostHogClient.shared.capture(
            .stepTextSlugCleanupCompleted,
            properties: [
                "steps_scanned": stepsScanned,
                "steps_updated": stepsUpdated,
            ],
        )
    }
}
