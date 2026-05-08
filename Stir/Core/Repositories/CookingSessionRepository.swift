// CookingSessionRepository
//
// Step-4 scope: create/advance/complete/resume a CookingSession per
// spec §4.11. Keeps every mutation funneled through viewContext.save()
// so CloudKit picks up changes for cross-device resume (Tonight Home
// "Resume" card on a second device).
//
// voiceEnabled is HARDCODED to false in step 4 (per Daniel's confirmed
// scope alignment). Step 6 flips this conditionally when the Live
// session actually opens.

import CoreData
import Foundation
import OSLog

@MainActor
final class CookingSessionRepository {
    private let controller: PersistenceController

    init(controller: PersistenceController) {
        self.controller = controller
    }

    // MARK: - Create

    /// Start a new cook session for the given RecipePlan. Caller ensures
    /// the RecipePlan's household matches the session's household.
    @discardableResult
    func createSession(
        on household: HouseholdProfile,
        for recipePlan: RecipePlan,
        entryPoint: CookingSession.EntryPoint,
    ) throws -> CookingSession {
        let context = controller.viewContext
        let now = Date()

        let session = CookingSession(context: context)
        session.id = UUID()
        session.household = household
        session.recipePlan = recipePlan
        session.typedEntryPoint = entryPoint
        session.typedStatus = .active
        session.currentStepIndex = 0
        session.startedAt = now
        session.endedAt = nil
        session.lowConfidenceCount = 0
        session.aiConversationVersion = ""
        session.voiceEnabled = false
        session.localNotificationIdsArray = []

        try controller.save()
        Logger.coreData.info("CookingSession created id=\(session.id?.uuidString ?? "?", privacy: .public)")
        return session
    }

    // MARK: - Update

    /// Move the current step pointer. Called on every Next/Previous tap.
    /// Persisting on every transition is cheap (single-attribute update)
    /// and matters for CloudKit cross-device resume — if a user swaps
    /// devices mid-cook, the second device should land on the same step.
    func advanceStep(_ session: CookingSession, to index: Int) throws {
        session.currentStepIndex = Int16(max(0, index))
        try controller.save()
    }

    /// Flush pending session edits (e.g. `localNotificationIdsArray`
    /// mutations made by TimerService) without touching step state. Use
    /// this instead of calling `advanceStep` just to force a save —
    /// advanceStep re-dirties `currentStepIndex` and is confusing in logs
    /// when no step transition occurred (CA2-R5).
    func saveSession(_ session: CookingSession) throws {
        _ = session  // callers pass the session so the call site documents intent
        try controller.save()
    }

    /// Transition to completed. Sets endedAt. OutcomeFeedback is persisted
    /// separately by OutcomeFeedbackRepository; this only touches the
    /// session state.
    ///
    /// Also flips `recipePlan.isSaved = true` so a cooked dish stays in
    /// Saved even if the user never starred it (SCA-10 — sticky save
    /// flag is the new gate alongside isFavorite/cooked-once).
    func markCompleted(_ session: CookingSession) throws {
        session.typedStatus = .completed
        session.endedAt = Date()
        if let plan = session.recipePlan {
            plan.isSaved = true
            plan.updatedAt = Date()
        }
        try controller.save()
    }

    /// Transition to abandoned (user exited without completing + didn't
    /// resume within the resumable window). Currently called only by a
    /// background cleanup path — step 4 doesn't auto-abandon, the user
    /// can always resume.
    func markAbandoned(_ session: CookingSession) throws {
        session.typedStatus = .abandoned
        session.endedAt = Date()
        try controller.save()
    }

    // MARK: - Reads

    /// Most recent `endedAt` for a completed cooking session in this
    /// household, if any. Used by SCA-64's UseSoonScheduler to suppress
    /// the use-soon nudge when the user has cooked in the trailing
    /// 24h (a recent cook satisfies the "use it soon" goal already).
    func mostRecentCompletedAt(for household: HouseholdProfile) throws -> Date? {
        let request = NSFetchRequest<CookingSession>(entityName: "CookingSession")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "recipePlan.household == %@", household),
            NSPredicate(format: "status == %@", CookingSession.Status.completed.rawValue),
            NSPredicate(format: "endedAt != nil"),
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "endedAt", ascending: false)]
        request.fetchLimit = 1
        let context = controller.viewContext
        do {
            return try context.fetch(request).first?.endedAt
        } catch {
            throw StirError.coreData(underlying: error)
        }
    }

    /// Most recent resumable session for a household (active, not
    /// deleted, endedAt == nil). Drives the Tonight Home resume-card.
    /// Nil if nothing to resume.
    func resumableSession(for household: HouseholdProfile) throws -> CookingSession? {
        let request = NSFetchRequest<CookingSession>(entityName: "CookingSession")
        // `recipePlan.deletedAt == nil` guards against the user
        // soft-deleting a plan from the Saved tab while a session is
        // still active for it — without this, Tonight's Resume card
        // would deep-link into Cook Mode for a tombstoned recipe.
        request.predicate = NSPredicate(
            format: "household == %@ AND deletedAt == nil AND endedAt == nil AND sessionStatus == %@ AND recipePlan.deletedAt == nil",
            household,
            CookingSession.Status.active.rawValue,
        )
        request.sortDescriptors = [NSSortDescriptor(key: "startedAt", ascending: false)]
        request.fetchLimit = 1
        do {
            return try controller.viewContext.fetch(request).first
        } catch {
            throw StirError.coreData(underlying: error)
        }
    }

    /// Completed sessions (newest first) for the Saved Meals surface.
    /// Session + its RecipePlan + optional OutcomeFeedback are
    /// prefetched so the view can render without round-trips.
    func recentCompletedSessions(for household: HouseholdProfile, limit: Int = 50) throws -> [CookingSession] {
        let request = NSFetchRequest<CookingSession>(entityName: "CookingSession")
        request.predicate = NSPredicate(
            format: "household == %@ AND deletedAt == nil AND sessionStatus == %@",
            household,
            CookingSession.Status.completed.rawValue,
        )
        request.sortDescriptors = [NSSortDescriptor(key: "endedAt", ascending: false)]
        request.fetchLimit = limit
        request.relationshipKeyPathsForPrefetching = ["recipePlan", "outcomeFeedback"]
        do {
            return try controller.viewContext.fetch(request)
        } catch {
            throw StirError.coreData(underlying: error)
        }
    }

    /// One row per non-deleted RecipePlan for the household, annotated with
    /// the most-recent completed CookingSession's endedAt + that session's
    /// rating (if rated). Sorted last-cooked-desc; un-cooked plans last,
    /// alphabetical by title within that bucket. Drives the Saved Meals
    /// surface — moved here from the view so SavedMealsView doesn't reach
    /// into NSFetchRequest directly.
    struct SavedMealEntry: Identifiable, Sendable {
        let id: UUID
        let title: String
        /// nil only if the RecipePlan row was nilled out between fetch and
        /// projection — practically never, but the view guards the cast.
        let plan: RecipePlan?
        let lastCookedAt: Date?
        let rating: Int?
    }

    func savedMealEntries(for household: HouseholdProfile) throws -> [SavedMealEntry] {
        let request = NSFetchRequest<RecipePlan>(entityName: "RecipePlan")
        // Only surface plans the user has actually engaged with:
        //   - sticky `isSaved` flag (set by setFavorite + markCompleted —
        //     SCA-10); OR
        //   - currently starred (`isFavorite == YES` — kept for pre-SCA-10
        //     rows that haven't passed through setFavorite/markCompleted
        //     since the fix landed); OR
        //   - has at least one non-deleted completed cook session (kept
        //     for the same backward-compat reason).
        //
        // Without this guard every dinner-solve's three RecipePlans land
        // in the Saved tab automatically — observed as duplicate /
        // auto-saved meals in the wild.
        //
        // SUBQUERY (not ANY) — both `deletedAt == nil` and
        // `sessionStatus == completed` must match the SAME session row;
        // ANY would let a non-deleted session and a separate completed
        // session jointly satisfy the filter.
        request.predicate = NSPredicate(
            format: """
            household == %@ AND deletedAt == nil AND \
            (isSaved == YES OR isFavorite == YES OR \
            SUBQUERY(cookingSessions, $s, $s.deletedAt == nil AND $s.sessionStatus == %@).@count > 0)
            """,
            household,
            CookingSession.Status.completed.rawValue,
        )
        request.relationshipKeyPathsForPrefetching = [
            "cookingSessions",
            "cookingSessions.outcomeFeedback",
            // Pre-faulted for SavedMealsView's search-by-ingredient path.
            // Without this, filtering by needle triggers a fault per row
            // (disk round-trip per keystroke at N rows × 1 fault).
            "ingredients",
        ]

        let plans: [RecipePlan]
        do {
            plans = try controller.viewContext.fetch(request)
        } catch {
            throw StirError.coreData(underlying: error)
        }

        let entries: [SavedMealEntry] = plans.compactMap { plan in
            // Skip nil-id plans (corrupted state) rather than generate a
            // fresh UUID per fetch — the generated id would differ on
            // every reload and break SwiftUI List identity, causing
            // favorite-toggle reloads to animate full insert/delete and
            // lose scroll position. RecipePlans are always created with
            // a non-nil id at persistence time; if one slips through
            // nil, surfacing it as a missing row is better than masking
            // it with an unstable identity.
            guard let planID = plan.id else {
                Logger.coreData.warning("savedMealEntries skipped plan with nil id (corrupted row)")
                return nil
            }
            let completedSessions = (plan.cookingSessions as? Set<CookingSession> ?? [])
                .filter { $0.typedStatus == .completed }
            let lastCompletedAt = completedSessions.compactMap { $0.endedAt }.max()
            let lastRating: Int? = completedSessions
                .compactMap { session -> (Date, Int)? in
                    guard let ended = session.endedAt,
                          let rating = session.outcomeFeedback?.rating,
                          rating > 0 else { return nil }
                    return (ended, Int(rating))
                }
                .max(by: { $0.0 < $1.0 })?
                .1

            return SavedMealEntry(
                id: planID,
                title: plan.title ?? "Untitled recipe",
                plan: plan,
                lastCookedAt: lastCompletedAt,
                rating: lastRating,
            )
        }
        return entries.sorted(by: Self.sortByLastCooked)
    }

    /// Comparator extracted for unit testing. Returns true when `a` should
    /// precede `b`. Last-cooked-desc; un-cooked entries fall to the bottom;
    /// alphabetical title within the un-cooked tail keeps ordering stable.
    static func sortByLastCooked(_ a: SavedMealEntry, _ b: SavedMealEntry) -> Bool {
        switch (a.lastCookedAt, b.lastCookedAt) {
        case let (.some(l), .some(r)): return l > r
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return a.title < b.title
        }
    }
}
