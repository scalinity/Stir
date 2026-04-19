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

    init(controller: PersistenceController = .shared) {
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

    /// Transition to completed. Sets endedAt. OutcomeFeedback is persisted
    /// separately by OutcomeFeedbackRepository; this only touches the
    /// session state.
    func markCompleted(_ session: CookingSession) throws {
        session.typedStatus = .completed
        session.endedAt = Date()
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

    /// Most recent resumable session for a household (active, not
    /// deleted, endedAt == nil). Drives the Tonight Home resume-card.
    /// Nil if nothing to resume.
    func resumableSession(for household: HouseholdProfile) throws -> CookingSession? {
        let request = NSFetchRequest<CookingSession>(entityName: "CookingSession")
        request.predicate = NSPredicate(
            format: "household == %@ AND deletedAt == nil AND endedAt == nil AND sessionStatus == %@",
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
}
