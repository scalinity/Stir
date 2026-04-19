// CookingSession type-safety extensions.
//
// Mirrors spec §4.11. Schema intentionally keeps every attribute optional
// at the Core Data layer for CloudKit compatibility; the computed props
// here enforce the real invariants (sessionStatus is always one of the
// enum values; currentStepIndex is clamped to the parent RecipePlan's
// step count; localNotificationIds round-trips via JSON).
//
// Step-4 constraint: voiceEnabled is ALWAYS false. Step 6 flips this
// conditionally once the Live session actually opens. Keeping the column
// here (not removing it) so the schema doesn't ping-pong between step
// builds.

import CoreData
import Foundation

extension CookingSession {
    /// Where the user entered Cook Mode from. Step 4 only emits `.solve`
    /// (coming from DishPreview after a solve). `.saved` arrives once
    /// saved-meals cook-again lands in commit 8; `.import` and
    /// `.leftovers` are step 7.
    enum EntryPoint: String, CaseIterable, Sendable {
        case solve       // from dinner solve → DishPreview → Start Cooking
        case saved       // from Saved Meals → Cook Again
        case imported    // step 7 — from imported recipe
        case leftovers   // step 7 — from leftovers follow-up
    }

    /// Session lifecycle. `active` + endedAt == nil = in-progress; `paused`
    /// is a UI-only state for Cook Mode itself; `completed` means ratings
    /// collected; `abandoned` means user exited without rating and didn't
    /// re-open within the resumable window.
    enum Status: String, CaseIterable, Sendable {
        case active
        case paused
        case completed
        case abandoned
    }

    var typedEntryPoint: EntryPoint {
        get { entryPoint.flatMap(EntryPoint.init(rawValue:)) ?? .solve }
        set { entryPoint = newValue.rawValue }
    }

    var typedStatus: Status {
        get { sessionStatus.flatMap(Status.init(rawValue:)) ?? .active }
        set { sessionStatus = newValue.rawValue }
    }

    /// Timers sorted by startedAt ascending (nil-startedAt timers last).
    var timerArray: [CookTimer] {
        let set = timers as? Set<CookTimer> ?? []
        return set.sorted { (a, b) in
            switch (a.startedAt, b.startedAt) {
            case let (.some(l), .some(r)): return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.id?.uuidString ?? "" < b.id?.uuidString ?? ""
            }
        }
    }

    /// SubstitutionEvents sorted by createdAt ascending.
    var substitutionArray: [SubstitutionEvent] {
        let set = substitutionEvents as? Set<SubstitutionEvent> ?? []
        return set.sorted { (a, b) in (a.createdAt ?? .distantPast) < (b.createdAt ?? .distantPast) }
    }

    /// Round-trip accessor for the JSON-encoded `localNotificationIdsJSON`
    /// Binary column. Returns `[]` when the column is nil or empty.
    var localNotificationIdsArray: [String] {
        get {
            guard let data = localNotificationIdsJSON, !data.isEmpty else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            localNotificationIdsJSON = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    var isSoftDeleted: Bool { deletedAt != nil }

    /// True when the session is in-progress (active + no endedAt). Drives
    /// the Resume-card affordance on Tonight Home.
    var isResumable: Bool {
        typedStatus == .active && endedAt == nil && !isSoftDeleted
    }
}
