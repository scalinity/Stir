// OutcomeFeedbackRepository
//
// Persists OutcomeFeedback per spec §4.15. The spec pins a uniqueness
// constraint on cookingSessionId that Core Data / CloudKit can't enforce
// at the schema level; this repo enforces it in Swift by upserting into
// the CookingSession.outcomeFeedback to-one relationship.

import CoreData
import Foundation

@MainActor
final class OutcomeFeedbackRepository {
    private let controller: PersistenceController

    init(controller: PersistenceController = .shared) {
        self.controller = controller
    }

    struct Input: Sendable {
        let rating: Int  // 1..5; clamped before persist
        let workload: OutcomeFeedback.Workload
        let taste: OutcomeFeedback.Taste
        let spiceLevel: OutcomeFeedback.SpiceLevel
        let wouldRepeat: Bool
        let notes: String?
        let leftoverCount: Int
    }

    /// Upsert: if the session already has an OutcomeFeedback, update in
    /// place; otherwise create. Keeps the 1:1 invariant (per spec §4.15)
    /// without relying on a DB unique constraint CloudKit can't enforce.
    @discardableResult
    func upsert(for session: CookingSession, input: Input) throws -> OutcomeFeedback {
        let context = controller.viewContext
        let now = Date()

        let feedback = session.outcomeFeedback ?? {
            let row = OutcomeFeedback(context: context)
            row.id = UUID()
            row.createdAt = now
            session.outcomeFeedback = row
            return row
        }()

        feedback.rating = Int16(max(1, min(5, input.rating)))
        feedback.typedWorkload = input.workload
        feedback.typedTaste = input.taste
        feedback.typedSpiceLevel = input.spiceLevel
        feedback.wouldRepeat = input.wouldRepeat
        feedback.notes = input.notes
        feedback.leftoverCount = Int16(max(0, input.leftoverCount))
        // createdAt is set on insert only; don't overwrite on update so
        // downstream sorts see the original timestamp.

        try controller.save()
        return feedback
    }
}
