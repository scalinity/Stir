// OutcomeFeedback type-safety extensions.
//
// Mirrors spec §4.15. The structured taxonomy (workload / taste /
// spiceLevel / wouldRepeat / leftoverCount) feeds step-7 preference
// memory; rating is the required-on-first-cook 1–5 stars.
//
// Spec pins "Constraint: unique cookingSessionId" but CloudKit can't
// enforce that at the schema level — CookingSession.outcomeFeedback is
// a to-one relationship, and OutcomeFeedbackRepository writes land only
// via that relationship (upsert-by-session semantics, enforced in
// Swift). If somehow two rows collide, the most recent createdAt wins.

import CoreData
import Foundation

extension OutcomeFeedback {
    enum Workload: String, CaseIterable, Sendable {
        case easy
        case medium
        case hard
    }

    enum Taste: String, CaseIterable, Sendable {
        case loved
        case good
        case ok
        case bad
    }

    enum SpiceLevel: String, CaseIterable, Sendable {
        case mild
        case medium
        case hot
        case tooHot = "too_hot"
    }

    var typedWorkload: Workload {
        get { workload.flatMap(Workload.init(rawValue:)) ?? .medium }
        set { workload = newValue.rawValue }
    }

    var typedTaste: Taste {
        get { taste.flatMap(Taste.init(rawValue:)) ?? .good }
        set { taste = newValue.rawValue }
    }

    var typedSpiceLevel: SpiceLevel {
        get { spiceLevel.flatMap(SpiceLevel.init(rawValue:)) ?? .medium }
        set { spiceLevel = newValue.rawValue }
    }

    /// Rating must be 1..5. UI clamps before writing but the computed
    /// read-path also clamps in case of on-disk drift.
    var clampedRating: Int {
        let v = Int(rating)
        return max(1, min(5, v))
    }
}
