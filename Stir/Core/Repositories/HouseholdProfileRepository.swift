// HouseholdProfileRepository
//
// Per-canonical-user accessor for the single `HouseholdProfile` row.
// Spec §4.1: one HouseholdProfile per user, keyed on canonicalUserKey. Step 2
// enforces this invariant at the repository layer (Core Data schema itself
// lacks the unique constraint because CloudKit sync doesn't enforce uniqueness).

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
        request.fetchLimit = 1
        do {
            return try controller.viewContext.fetch(request).first
        } catch {
            throw StirError.coreData(underlying: error)
        }
    }

    /// Fetch the existing profile for this canonical key, or create one with
    /// sensible defaults. Used by RootCoordinator right after
    /// IdentityService.resolve() so every downstream feature has a non-nil
    /// profile to attach to.
    @discardableResult
    func ensureHouseholdProfile(for canonicalUserKey: String) throws -> HouseholdProfile {
        if let existing = try findExisting(for: canonicalUserKey) {
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
