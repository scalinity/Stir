// CookTimerRepository
//
// Persists CookTimer state transitions per spec §4.13. Owns the Core
// Data side; TimerService owns the in-memory scheduling + notification
// machinery and calls this repo to durably record transitions.

import CoreData
import Foundation

@MainActor
final class CookTimerRepository {
    private let controller: PersistenceController
    private let persist: @MainActor () throws -> Void

    init(controller: PersistenceController, save: (@MainActor () throws -> Void)? = nil) {
        self.controller = controller
        self.persist = save ?? controller.save
    }

    /// Keep failed transitions and session notification identifiers out of
    /// later saves. The injectable save operation exercises failure paths.
    private func save() throws {
        do {
            try persist()
        } catch {
            controller.viewContext.rollback()
            throw error
        }
    }

    @discardableResult
    func createTimer(
        for session: CookingSession,
        step: RecipeStep?,
        label: String,
        durationSec: Int,
    ) throws -> CookTimer {
        let context = controller.viewContext
        let timer = CookTimer(context: context)
        timer.id = UUID()
        timer.cookingSession = session
        timer.step = step
        timer.label = label
        timer.durationSec = Int32(max(0, durationSec))
        timer.typedState = .pending
        try save()
        return timer
    }

    func start(_ timer: CookTimer, at date: Date = Date()) throws {
        timer.startedAt = date
        timer.endedAt = nil
        timer.pausedRemainingSec = -1
        timer.typedState = .running
        try save()
    }

    /// Save the remaining seconds with paused state. Resume and the
    /// countdown view both use this snapshot after service recreation.
    func pause(_ timer: CookTimer, pausedRemainingSec: Int) throws {
        timer.typedState = .paused
        timer.pausedRemainingSec = Int32(max(0, pausedRemainingSec))
        try save()
    }

    /// Resume with startedAt derived from resumedAt + saved remaining
    /// seconds - durationSec. Clear the snapshot in the same save.
    func resume(_ timer: CookTimer, newStartedAt: Date) throws {
        timer.startedAt = newStartedAt
        timer.typedState = .running
        timer.pausedRemainingSec = -1
        try save()
    }

    func markCompleted(_ timer: CookTimer, at date: Date = Date()) throws {
        timer.endedAt = date
        timer.typedState = .completed
        timer.pausedRemainingSec = -1
        try save()
    }

    func cancel(_ timer: CookTimer, at date: Date = Date()) throws {
        timer.endedAt = date
        timer.typedState = .cancelled
        timer.pausedRemainingSec = -1
        try save()
    }

    /// All timers for a session, sorted by startedAt (nil-last). Used
    /// for in-app list rendering in StepCardView.
    func timers(for session: CookingSession) -> [CookTimer] {
        session.timerArray
    }
}
