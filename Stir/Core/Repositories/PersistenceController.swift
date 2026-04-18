// PersistenceController
//
// Owns the `NSPersistentCloudKitContainer` for Stir. Wraps the Core Data store
// at `Stir.sqlite` (Application Support), backed by the CloudKit private
// database in `iCloud.com.scalinity.stir`.
//
// Design:
//   - Single viewContext, main-actor-bound. All step-2 repositories read/write
//     through this context.
//   - Persistent history tracking + remote-change notifications enabled so
//     CloudKit sync merges land correctly when other devices push updates.
//   - No custom record zones (premature — would force migration work later).
//   - In-memory mode exposed for tests.
//
// ASSUMPTION: store URL defaults to Application Support (NSPersistentContainer
// default). Not overridden — simplest cross-device behavior. Flag if a shared
// App Group becomes necessary in step 7 (extensions).

import CoreData
import Foundation
import OSLog

@MainActor
final class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer

    var viewContext: NSManagedObjectContext { container.viewContext }

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "Stir")

        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("PersistenceController: NSPersistentCloudKitContainer returned no store descriptions — model bundle missing?")
        }

        if inMemory {
            description.url = URL(fileURLWithPath: "/dev/null")
            description.cloudKitContainerOptions = nil
            Logger.coreData.info("initializing in-memory store (tests)")
        } else {
            // Persistent history tracking is REQUIRED for CloudKit sync.
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

            // Bind the store to the Stir CloudKit private DB.
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: "iCloud.com.scalinity.stir",
            )
        }

        container.loadPersistentStores { [container] storeDescription, error in
            if let error {
                Logger.coreData.error(
                    "failed to load persistent store at \(storeDescription.url?.absoluteString ?? "<unknown>", privacy: .public): \(error.localizedDescription, privacy: .public)",
                )
                // Fatal — step 2 cannot proceed without the store. Step 9's
                // RootCoordinator surfaces a recovery screen if this becomes
                // a recoverable class of error; for now, crashing with a
                // clear message is more honest than limping along.
                fatalError("PersistenceController.loadPersistentStores: \(error)")
            }
            _ = container  // capture silences unused closure-capture warning
            Logger.coreData.info("persistent store loaded at \(storeDescription.url?.absoluteString ?? "<in-memory>", privacy: .public)")
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.name = "viewContext.main"
    }

    /// Commit the viewContext's pending changes. Throws StirError.coreData on failure.
    func save() throws {
        let context = container.viewContext
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            Logger.coreData.error("viewContext save failed: \(error.localizedDescription, privacy: .public)")
            throw StirError.coreData(underlying: error)
        }
    }
}
