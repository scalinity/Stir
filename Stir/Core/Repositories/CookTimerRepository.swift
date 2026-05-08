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

    init(controller: PersistenceController) {
        self.controller = controller
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
        try controller.save()
        return timer
    }

    func start(_ timer: CookTimer, at date: Date = Date()) throws {
        timer.startedAt = date
        timer.endedAt = nil
        timer.typedState = .running
        try controller.save()
    }

    /// Persist a PAUSE transition. The "elapsed so far" math lives in
    /// TimerService's in-memory state — when the user resumes, Service
    /// calls `resume(timer:pausedDuration:)` with the adjusted start time
    /// so `startedAt + durationSec` remains the authoritative fire date.
    ///
    /// `pausedRemainingSec` is also persisted (DB1-1 fix) so cold-launch
    /// reconcile in CookModeViewModel can show the correct Lock Screen
    /// remaining time without consulting the in-memory pauseStartedAt
    /// map (process-scoped, gone after force-quit). Callers pass the
    /// snapshot computed at pause time; nil means the column stays clear.
    func pause(_ timer: CookTimer, pausedRemainingSec: Int) throws {
        timer.typedState = .paused
        timer.pausedRemainingSec = Int32(max(0, pausedRemainingSec))
        try controller.save()
    }

    /// Resume a paused timer with a recomputed startedAt so the fire
    /// date moves forward by the paused duration. `newStartedAt` should
    /// be `originalStartedAt + pausedDuration`. Clears the persisted
    /// pausedRemainingSec sentinel.
    func resume(_ timer: CookTimer, newStartedAt: Date) throws {
        timer.startedAt = newStartedAt
        timer.typedState = .running
        timer.pausedRemainingSec = -1
        try controller.save()
    }

    func markCompleted(_ timer: CookTimer, at date: Date = Date()) throws {
        timer.endedAt = date
        timer.typedState = .completed
        timer.pausedRemainingSec = -1
        try controller.save()
    }

    func cancel(_ timer: CookTimer, at date: Date = Date()) throws {
        timer.endedAt = date
        timer.typedState = .cancelled
        timer.pausedRemainingSec = -1
        try controller.save()
    }

    /// All timers for a session, sorted by startedAt (nil-last). Used
    /// for in-app list rendering in StepCardView.
    func timers(for session: CookingSession) -> [CookTimer] {
        session.timerArray
    }
}
