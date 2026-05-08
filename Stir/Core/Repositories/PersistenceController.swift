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

    /// SCA-98 privacy contract: the shape of the runtime save-failure log
    /// line. Exposed as a constant so `PersistenceControllerSaveTests`
    /// can assert it never embeds `error.localizedDescription` (Core Data's
    /// `NSValidationError` userInfo includes user-supplied attribute
    /// values verbatim, which would publish to system logs at `.public`).
    /// Any change to the catch-block log line below MUST be reflected
    /// here, or the regression test will fail.
    internal static let saveFailureLogFormat = "viewContext save failed: domain=<domain> code=<code>"

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
    ///
    /// On save failure: rollback before rethrowing. Without rollback, the
    /// dirty objects from the failed transaction stay registered in
    /// viewContext and get committed on the NEXT successful save, silently
    /// persisting stale / partial data from an earlier operation. This was
    /// flagged as CA2-1 during the step-3 review.
    func save() throws {
        let context = container.viewContext
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            // SCA-98: log domain+code only. NSError.localizedDescription on Core Data
            // validation failures embeds the rejected attribute value verbatim
            // (e.g. `"<displayName>" is not a valid value for the attribute "displayName"`)
            // — that's user-supplied content, and `.public` interpolation publishes it
            // to system logs. domain+code preserves enough signal to debug while
            // keeping any user-typed string out of the log stream. Sentry still
            // gets the wrapped StirError.coreData(underlying:) below with full context.
            let nserror = error as NSError
            Logger.coreData.error(
                "viewContext save failed: domain=\(nserror.domain, privacy: .public) code=\(nserror.code, privacy: .public)"
            )
            context.rollback()
            throw StirError.coreData(underlying: error)
        }
    }
}
