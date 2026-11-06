// CurrentHouseholdStore
//
// Holds the pre-created HouseholdProfile for the current user. RootCoordinator
// selects it at bootstrap and after reconciliation of CloudKit imports.
// SettingsRootView → HouseholdPreferencesView consumes it.

import CoreData
import Foundation
import Observation

@MainActor
@Observable
final class CurrentHouseholdStore {
    private(set) var profile: HouseholdProfile?

    func set(_ profile: HouseholdProfile) {
        self.profile = profile
    }

    func clear() {
        self.profile = nil
    }
}
