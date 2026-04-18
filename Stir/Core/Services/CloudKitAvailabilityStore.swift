// CloudKitAvailabilityStore
//
// Publishes the current iCloud availability to SwiftUI views. RootCoordinator
// keeps it in sync with IdentityService's observed account changes.
// Settings → Sync Status reads `isAvailable` + rendered copy.

import Foundation
import Observation

@MainActor
@Observable
final class CloudKitAvailabilityStore {
    private(set) var isAvailable: Bool = false
    private(set) var lastResolvedKey: CanonicalUserKey? = nil

    func update(with key: CanonicalUserKey) {
        self.lastResolvedKey = key
        self.isAvailable = key.isCloudKit
    }
}
