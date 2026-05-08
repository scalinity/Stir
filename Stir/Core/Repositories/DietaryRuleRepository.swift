// DietaryRuleRepository
//
// Create/read/deactivate DietaryRule rows attached to a HouseholdProfile.
// Enforces the spec §4.2 uniqueness constraint `(household, kind, value)` at
// the application layer (CloudKit-compatible Core Data schema can't enforce
// it natively).

import CoreData
import Foundation

@MainActor
final class DietaryRuleRepository {
    private let controller: PersistenceController

    init(controller: PersistenceController) {
        self.controller = controller
    }

    /// Add or reactivate a rule with the given (kind, value). If an inactive
    /// row already exists (user toggled this rule off previously), reactivate
    /// it in place rather than inserting a duplicate — the uniqueness
    /// constraint is `(household, kind, value)` regardless of isActive, and
    /// repeated off/on toggling would otherwise accumulate cruft.
    @discardableResult
    func add(
        to profile: HouseholdProfile,
        kind: DietaryRule.Kind,
        value: String,
        severity: DietaryRule.Severity = .soft,
        source: DietaryRule.Source = .user,
    ) throws -> DietaryRule {
        let context = controller.viewContext

        if let existing = profile.dietaryRuleArray.first(where: { rule in
            rule.typedKind == kind
            && rule.value?.caseInsensitiveCompare(value) == .orderedSame
        }) {
            var mutated = false
            if !existing.isActive {
                existing.isActive = true
                mutated = true
            }
            if existing.typedSeverity != severity {
                existing.typedSeverity = severity
                mutated = true
            }
            if existing.typedSource != source {
                existing.typedSource = source
                mutated = true
            }
            if mutated {
                existing.updatedAt = Date()
                try controller.save()
            }
            return existing
        }

        let rule = DietaryRule(context: context)
        rule.id = UUID()
        rule.typedKind = kind
        rule.value = value
        rule.typedSeverity = severity
        rule.typedSource = source
        rule.isActive = true

        let now = Date()
        rule.createdAt = now
        rule.updatedAt = now
        rule.household = profile

        try controller.save()
        return rule
    }

    /// Soft-deactivate a rule (sets isActive=false). Per spec §4.2 DietaryRule
    /// is hard-delete on cascade from HouseholdProfile; within a lifecycle we
    /// prefer isActive toggling so the user can re-enable without losing state.
    func deactivate(_ rule: DietaryRule) throws {
        rule.isActive = false
        rule.updatedAt = Date()
        try controller.save()
    }

    /// Hard-delete a rule (used by full-delete paths; not the default UI action).
    func delete(_ rule: DietaryRule) throws {
        let context = controller.viewContext
        context.delete(rule)
        try controller.save()
    }
}
