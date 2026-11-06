// HouseholdProfileRepository
//
// Resolves one active household graph per canonical user. CloudKit can import
// duplicate roots; ADR 0039 keeps them as empty anchors for late child imports
// and moves their content to a deterministic survivor without cascade deletion.

import CoreData
import Foundation
import OSLog

@MainActor
final class HouseholdProfileRepository {
    private let controller: PersistenceController

    init(controller: PersistenceController) {
        self.controller = controller
    }

    /// Read-only lookup. Returns the existing profile for this canonical key
    /// or nil; never creates. Used by `RootCoordinator.attemptFastPathLaunch`
    /// to decide whether warm-launch can render Tonight Home immediately
    /// against cached state. Throws on Core Data fetch errors only — a
    /// missing row is `nil`, not an error.
    func findExisting(for canonicalUserKey: String) throws -> HouseholdProfile? {
        let request = NSFetchRequest<HouseholdProfile>(entityName: "HouseholdProfile")
        request.predicate = NSPredicate(
            format: "canonicalUserKey == %@ AND deletedAt == nil",
            canonicalUserKey,
        )
        do {
            return try controller.viewContext.fetch(request).sorted(by: Self.precedes).first
        } catch {
            throw StirError.coreData(underlying: error)
        }
    }

    /// Fetch the existing profile for this canonical key, or create one with
    /// sensible defaults. Used by RootCoordinator right after
    /// IdentityService.resolve() so every downstream feature has a non-nil
    /// profile to attach to.
    @discardableResult
    func ensureHouseholdProfile(
        for canonicalUserKey: String,
        promotingInstallationKey: String? = nil,
    ) throws -> HouseholdProfile {
        // The coordinator supplies only its own prior installation key.
        // A genuine ck:A -> ck:B switch never enters this branch.
        if let installationKey = promotingInstallationKey,
           installationKey.hasPrefix("install:"), canonicalUserKey.hasPrefix("ck:") {
            for profile in try profiles(for: installationKey) {
                profile.canonicalUserKey = canonicalUserKey
            }
        }
        if let existing = try reconcileProfiles(for: canonicalUserKey) {
            Logger.coreData.debug("reusing HouseholdProfile for existing user")
            return existing
        }
        let context = controller.viewContext

        // New row — populate required fields.
        let profile = HouseholdProfile(context: context)
        profile.id = UUID()
        profile.canonicalUserKey = canonicalUserKey
        profile.locale = Locale.current.identifier
        profile.timezone = TimeZone.current.identifier
        profile.servingsDefault = 2
        profile.preferredUnits = HouseholdProfile.PreferredUnits.imperial.rawValue
        profile.onboardingCompleted = false

        let now = Date()
        profile.createdAt = now
        profile.updatedAt = now

        try controller.save()
        Logger.coreData.info("created HouseholdProfile for new user")
        return profile
    }

    /// Consolidate only an existing identity. Remote-change handling must not
    /// create a replacement household while a deletion is being propagated.
    @discardableResult
    func reconcileProfiles(for canonicalUserKey: String) throws -> HouseholdProfile? {
        let matches = try profiles(for: canonicalUserKey).sorted(by: Self.precedes)
        guard let survivor = matches.first else { return nil }
        let completed = matches.filter(\.onboardingCompleted)
        let settings = (completed.isEmpty ? matches : completed).max { left, right in
            let leftDate = left.updatedAt ?? .distantPast
            let rightDate = right.updatedAt ?? .distantPast
            return leftDate == rightDate ? Self.precedes(right, left) : leftDate < rightDate
        }!
        if settings !== survivor {
            survivor.locale = settings.locale
            survivor.timezone = settings.timezone
            survivor.servingsDefault = settings.servingsDefault
            survivor.preferredUnits = settings.preferredUnits
            survivor.updatedAt = settings.updatedAt
        }
        survivor.onboardingCompleted = !completed.isEmpty

        for duplicate in matches.dropFirst() {
            // Every household-owned entity has an inverse `household` link.
            // Copy the set before changing inverses; mutating it in-place
            // during enumeration would skip children. Never delete roots:
            // CloudKit may deliver one of their children in a later import.
            for relationship in duplicate.entity.relationshipsByName.values
                where relationship.isToMany && relationship.inverseRelationship?.name == "household" {
                let children = (duplicate.value(forKey: relationship.name) as? NSSet)?.allObjects ?? []
                for case let child as NSManagedObject in children {
                    child.setValue(survivor, forKey: "household")
                }
            }
        }
        reconcilePreferences(on: survivor)
        try controller.save()
        return survivor
    }

    private func profiles(for canonicalUserKey: String) throws -> [HouseholdProfile] {
        let request = NSFetchRequest<HouseholdProfile>(entityName: "HouseholdProfile")
        request.predicate = NSPredicate(format: "canonicalUserKey == %@ AND deletedAt == nil", canonicalUserKey)
        do {
            return try controller.viewContext.fetch(request)
        } catch {
            throw StirError.coreData(underlying: error)
        }
    }

    /// Only immutable creation data chooses the root, so copying newer
    /// preferences cannot switch the survivor on the next reconciliation.
    private static func precedes(_ left: HouseholdProfile, _ right: HouseholdProfile) -> Bool {
        let leftDate = left.createdAt ?? .distantFuture
        let rightDate = right.createdAt ?? .distantFuture
        if leftDate != rightDate { return leftDate < rightDate }
        let leftID = left.id?.uuidString ?? left.objectID.uriRepresentation().absoluteString
        let rightID = right.id?.uuidString ?? right.objectID.uriRepresentation().absoluteString
        return leftID < rightID
    }

    /// These two collections have logical uniqueness independent of record
    /// IDs. Keep the most recently edited state, including a deactivation,
    /// so a stale imported copy cannot reactivate a removed preference.
    private func reconcilePreferences(on household: HouseholdProfile) {
        let rules = Dictionary(grouping: household.dietaryRuleArray) {
            "\($0.kind ?? ""):\(($0.value ?? "").lowercased())"
        }
        let equipment = Dictionary(grouping: household.kitchenEquipmentArray) { $0.code ?? "" }
        for group in Array(rules.values).map({ $0 as [NSManagedObject] })
            + Array(equipment.values).map({ $0 as [NSManagedObject] }) {
            let ordered = group.sorted { left, right in
                let leftDate = left.value(forKey: "updatedAt") as? Date ?? .distantPast
                let rightDate = right.value(forKey: "updatedAt") as? Date ?? .distantPast
                if leftDate != rightDate { return leftDate > rightDate }
                let leftID = (left.value(forKey: "id") as? UUID)?.uuidString ?? left.objectID.uriRepresentation().absoluteString
                let rightID = (right.value(forKey: "id") as? UUID)?.uuidString ?? right.objectID.uriRepresentation().absoluteString
                return leftID < rightID
            }
            for duplicate in ordered.dropFirst() { controller.viewContext.delete(duplicate) }
        }
    }

    /// Mark onboardingCompleted = true + stamp updatedAt. Called from the final
    /// step of the onboarding flow (Setup 2 Continue button).
    func markOnboardingComplete(_ profile: HouseholdProfile) throws {
        profile.onboardingCompleted = true
        profile.updatedAt = Date()
        try controller.save()
        Logger.coreData.info("HouseholdProfile onboardingCompleted = true")
    }

    /// Update servings / preferred units. Called from Settings → Household Preferences.
    func update(
        _ profile: HouseholdProfile,
        servingsDefault: Int16? = nil,
        preferredUnits: HouseholdProfile.PreferredUnits? = nil,
    ) throws {
        if let servingsDefault { profile.servingsDefault = servingsDefault }
        if let preferredUnits { profile.preferredUnits = preferredUnits.rawValue }
        profile.updatedAt = Date()
        try controller.save()
    }
}
