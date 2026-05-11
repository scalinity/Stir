// PantryTombstoneReaper
//
// SCA-97 — drives `PantryItemRepository.purgeTombstones(...)` on a
// foreground cadence so long-running users don't accumulate tombstone
// rows indefinitely.
//
// Soft-delete contract: `PantryItemRepository.softDelete` writes
// `deletedAt`; every UI/AI surface filters via `deletedAt == nil`, so
// soft-deleted rows are invisible. CCPA scope is satisfied via the
// account-delete path (SCA-61 + SCA-88 — blows away the entire
// CloudKit zone). This reaper only handles steady-state hygiene:
// preventing the tombstone set from growing without bound.
//
// Cadence: once per day. Persisted via UserDefaults under a
// namespaced key (`com.scalinity.stir.pantry.tombstoneReaper.lastRunAt`).
// Foreground-triggered from `RootView`'s `.onChange(of: scenePhase)`
// block, alongside the `softDeleteExpired` sweep. A scheduled job
// (BGAppRefreshTask) was considered but rejected: foreground hook
// satisfies the "purge eventually" goal without the BGTask dance
// (BGTaskScheduler quotas, simulator unreliability, NSURLSessionConfig
// background context drift). Worst case for never-foregrounded users:
// tombstones live until next launch — same upper bound as the rest of
// the foreground-sync model.
//
// Retention: 90 days. Long enough to absorb a "I deleted that by
// accident, can I get it back" support window (no undo-on-delete UI
// today, but the option exists). Short enough that CloudKit zone size
// stays bounded for power users.
//
// Errors are LOGGED, never thrown to the UI. Hygiene-grade work — a
// Core Data fault here shouldn't surface to the user, who has no
// actionable recourse. The next foreground pass retries from the
// same `last_run_at` (the timestamp moves only AFTER a successful
// purge, so failed runs don't poison the cadence).

import Foundation
import os

/// Runs `PantryItemRepository.purgeTombstones(...)` on a daily cadence.
@MainActor
final class PantryTombstoneReaper {
    /// 90-day retention window for soft-deleted pantry rows.
    /// `nonisolated` so init parameter defaults can read it from a
    /// non-MainActor context (Swift 6 isolation requirement).
    nonisolated static let defaultRetention: TimeInterval = 90 * 24 * 60 * 60

    /// Once-per-day cadence for the foreground trigger. Repeated
    /// foreground transitions within a 24h window are free no-ops —
    /// the reaper's CloudKit-zone-mutating work is hygiene-grade and
    /// daily is the tightest cadence that's worth running given the
    /// 90-day retention window.
    ///
    /// SCA-311 S3: named `cadenceWindow` (not `cadenceInterval`) to
    /// read as "skip if elapsed < this window" rather than "fires
    /// every N seconds" — the reaper is foreground-triggered, not
    /// timer-driven.
    nonisolated static let cadenceWindow: TimeInterval = 24 * 60 * 60

    /// UserDefaults key for the last-run timestamp. Namespaced under
    /// `com.scalinity.stir.*` mirroring `ScanFlashMode`'s
    /// `@AppStorage("com.scalinity.stir.scan.flashMode")` precedent.
    nonisolated static let lastRunDefaultsKey = "com.scalinity.stir.pantry.tombstoneReaper.lastRunAt"

    private let repository: PantryItemRepository
    private let retention: TimeInterval
    private let cadence: TimeInterval
    private let defaults: UserDefaults
    private let telemetry: @MainActor (_ rowsPurged: Int, _ retentionDays: Int) -> Void
    private let logger: Logger

    /// - Parameters:
    ///   - repository: the pantry repo whose `purgeTombstones` will run
    ///   - retention: how old a tombstone must be before purging (default 90d)
    ///   - cadence: minimum interval between runs (default 24h)
    ///   - defaults: UserDefaults instance — injectable for tests
    ///   - telemetry: callback fired AFTER a successful purge with the
    ///     rows-purged count + the retention window in whole days.
    ///     Default emits `pantry_tombstone_reaper_ran` to PostHog on
    ///     every successful run (including zero-row passes — the
    ///     funnel needs a continuous time-series so cadence regressions
    ///     surface as missing emissions). Tests inject a no-op or a
    ///     count-collector.
    init(
        repository: PantryItemRepository,
        retention: TimeInterval = PantryTombstoneReaper.defaultRetention,
        cadence: TimeInterval = PantryTombstoneReaper.cadenceWindow,
        defaults: UserDefaults = .standard,
        telemetry: @MainActor @escaping (_ rowsPurged: Int, _ retentionDays: Int) -> Void = PantryTombstoneReaper.defaultTelemetry,
    ) {
        self.repository = repository
        self.retention = retention
        self.cadence = cadence
        self.defaults = defaults
        self.telemetry = telemetry
        self.logger = Logger(subsystem: "com.scalinity.stir", category: "PantryTombstoneReaper")
    }

    /// Foreground entry point. Runs the purge if `cadence` has elapsed
    /// since the last successful run; otherwise returns 0 without
    /// touching Core Data.
    ///
    /// SCA-300 W8: the repository call hops to a background NSManaged-
    /// ObjectContext so this @MainActor entry point never blocks the
    /// UI thread on disk I/O. The cadence gate + telemetry stay on
    /// MainActor; only the fetch / `context.delete()` loop / `save()`
    /// runs off-main.
    ///
    /// - Parameters:
    ///   - household: scope for the purge
    ///   - now: current wall clock (override for tests)
    /// - Returns: number of rows hard-deleted this call. 0 when the
    ///   cadence gate held, when no rows were eligible, or when the
    ///   purge errored. Telemetry fires on every successful run
    ///   (including zero-row passes) so the cadence funnel sees
    ///   continuous time-series coverage — see the design comment on
    ///   `defaultTelemetry` below; it does NOT fire when the cadence
    ///   gate short-circuits or when the purge throws.
    @discardableResult
    func runIfDue(for household: HouseholdProfile, now: Date = Date()) async -> Int {
        // Cadence gate. last_run_at = nil treats as "never run" → run
        // immediately. New-install behavior: there's nothing to purge,
        // the run returns 0 + we mark last_run_at so subsequent
        // foregrounds are gated for cadence duration. Saves a wasted
        // pass on every cold start of an empty install.
        if let last = readLastRunAt(), now.timeIntervalSince(last) < cadence {
            return 0
        }

        let cutoff = now.addingTimeInterval(-retention)
        do {
            let purged = try await repository.purgeTombstonesAsync(olderThan: cutoff, for: household)
            // Mark last_run_at AFTER success so a failed pass is
            // retried on the very next foreground rather than waiting
            // a full cadence cycle. A zero-row pass is still a success
            // — the predicate ran, it's just that nothing was
            // eligible.
            writeLastRunAt(now)
            telemetry(purged, Int(retention / 86_400))
            return purged
        } catch {
            logger.error(
                "purgeTombstones failed: \(error.localizedDescription, privacy: .private)",
            )
            // Don't update last_run_at on failure — next foreground
            // retries.
            return 0
        }
    }

    /// Read-only view of the last-run timestamp. Returns `nil` when
    /// the reaper has never run on this installation.
    var lastRunAt: Date? {
        readLastRunAt()
    }

    /// Test seam — wipe the cadence key so a second `runIfDue` call in
    /// the same test re-runs the work without test-time skew. Mirrors
    /// `WidgetNudgeService.reset()`.
    func reset() {
        defaults.removeObject(forKey: Self.lastRunDefaultsKey)
    }

    private func readLastRunAt() -> Date? {
        let raw = defaults.double(forKey: Self.lastRunDefaultsKey)
        // 0.0 is the UserDefaults sentinel for "key absent / not a
        // double". Treat as never-run, NOT as 1970-01-01 (the latter
        // would always satisfy `cadence` and run every foreground —
        // the bug would be silent).
        guard raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    private func writeLastRunAt(_ date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.lastRunDefaultsKey)
    }

    /// Default telemetry emitter — fires `pantry_tombstone_reaper_ran`
    /// with `rows_purged` + `retention_days`. Emits on every successful
    /// run (including zero-row passes) so the funnel sees continuous
    /// cadence coverage; missing emissions flag a wiring regression.
    /// Skipping no-op runs would conflate "reaper not running" with
    /// "reaper running cleanly" — the support story we want is
    /// "reaper ran today and purged N rows".
    ///
    /// SCA-311 S29: the `nonisolated static let` with `@MainActor`
    /// closure type is the intentional shape — `nonisolated` lets the
    /// init parameter default reference this from a non-MainActor
    /// context (Swift 6 strict mode), while the closure itself still
    /// hops back to the main actor before invoking `PostHogClient` so
    /// the analytics call site stays main-actor-isolated.
    nonisolated static let defaultTelemetry: @MainActor (_ rowsPurged: Int, _ retentionDays: Int) -> Void = { rowsPurged, retentionDays in
        PostHogClient.shared.capture(
            .pantryTombstoneReaperRan,
            properties: [
                "rows_purged": rowsPurged,
                "retention_days": retentionDays,
            ],
        )
    }
}
