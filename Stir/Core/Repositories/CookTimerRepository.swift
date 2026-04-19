// CookTimerRepository
//
// Persists CookTimer state transitions per spec §4.13. Owns the Core
// Data side; TimerService owns the in-memory scheduling + notification
// machinery and calls this repo to durably record transitions.

import CoreData
import Foundation
import OSLog

@MainActor
final class CookTimerRepository {
    private let controller: PersistenceController

    init(controller: PersistenceController = .shared) {
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
    func pause(_ timer: CookTimer) throws {
        timer.typedState = .paused
        try controller.save()
    }

    /// Resume a paused timer with a recomputed startedAt so the fire
    /// date moves forward by the paused duration. `newStartedAt` should
    /// be `originalStartedAt + pausedDuration`.
    func resume(_ timer: CookTimer, newStartedAt: Date) throws {
        timer.startedAt = newStartedAt
        timer.typedState = .running
        try controller.save()
    }

    func markCompleted(_ timer: CookTimer, at date: Date = Date()) throws {
        timer.endedAt = date
        timer.typedState = .completed
        try controller.save()
    }

    func cancel(_ timer: CookTimer, at date: Date = Date()) throws {
        timer.endedAt = date
        timer.typedState = .cancelled
        try controller.save()
    }

    /// All timers for a session, sorted by startedAt (nil-last). Used
    /// for in-app list rendering in StepCardView.
    func timers(for session: CookingSession) -> [CookTimer] {
        session.timerArray
    }
}
