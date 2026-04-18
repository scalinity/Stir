// DietaryRule type-safety extensions.
//
// Per spec §4.2:
//   kind     ∈ {allergy, diet, dislike, goal}
//   severity ∈ {hard, soft}
//   source   ∈ {user, learned}
// These live as raw strings in Core Data (for CloudKit compatibility); the
// typed accessors here are the preferred read/write path from Swift.

import CoreData
import Foundation

extension DietaryRule {
    enum Kind: String, CaseIterable, Sendable {
        case allergy
        case diet
        case dislike
        case goal
    }

    enum Severity: String, CaseIterable, Sendable {
        case hard
        case soft
    }

    enum Source: String, CaseIterable, Sendable {
        case user
        case learned
    }

    var typedKind: Kind? {
        get { kind.flatMap(Kind.init(rawValue:)) }
        set { kind = newValue?.rawValue }
    }

    var typedSeverity: Severity {
        get { severity.flatMap(Severity.init(rawValue:)) ?? .soft }
        set { severity = newValue.rawValue }
    }

    var typedSource: Source {
        get { source.flatMap(Source.init(rawValue:)) ?? .user }
        set { source = newValue.rawValue }
    }
}
