// Household-scoped deletion. Normal Core Data deletes propagate through CloudKit;
// deleting the entire record zone could erase a different account's local rows.
import CoreData
import Foundation
import Observation

@MainActor
@Observable
final class HouseholdDataDeletionService {
    struct State: Codable, Equatable {
        let cutoff: Date
        let isCloudKit: Bool
        var awaitingAcknowledgement = true
        var lastEraseSavedAt: Date?
        var cloudExportedAt: Date?
        var storeIdentifiers: [String] = []
    }

    private static let storageKey = "stir.householdDeletion.v1"
    private let controller: PersistenceController
    private let defaults: UserDefaults
    private let save: () throws -> Void
    private var states: [String: State]
    private var unreadableState = false
    private var currentCanonicalKey: String?
    private var identityResolvedAt = Date.distantFuture
    @ObservationIgnored private var exportIdentities: [UUID: String] = [:]
    @ObservationIgnored private var exportObserver: NSObjectProtocol?

    init(controller: PersistenceController, defaults: UserDefaults = .standard, save: (() throws -> Void)? = nil) {
        self.controller = controller
        self.defaults = defaults
        self.save = save ?? { try controller.save() }
        if let data = defaults.data(forKey: Self.storageKey) {
            do { states = try JSONDecoder().decode([String: State].self, from: data) }
            catch { states = [:]; unreadableState = true }
        } else {
            states = [:]
        }
        exportObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: controller.container,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event,
                event.type == .export else { return }
            let identifier = event.identifier
            let startedAt = event.startDate
            let endedAt = event.endDate
            let succeeded = event.succeeded
            let storeIdentifier = event.storeIdentifier
            Task { @MainActor [weak self] in
                self?.observeExport(identifier: identifier, storeIdentifier: storeIdentifier,
                                    startedAt: startedAt, endedAt: endedAt, succeeded: succeeded)
            }
        }
    }

    deinit {
        if let exportObserver { NotificationCenter.default.removeObserver(exportObserver) }
    }

    func state(for canonicalUserKey: String) -> State? { states[canonicalUserKey] }

    func setCurrentIdentity(_ canonicalUserKey: String) {
        guard currentCanonicalKey != canonicalUserKey else { return }
        currentCanonicalKey = canonicalUserKey
        identityResolvedAt = Date()
        exportIdentities.removeAll()
    }

    func isAwaitingAcknowledgement(for canonicalUserKey: String) -> Bool {
        unreadableState || states[canonicalUserKey]?.awaitingAcknowledgement == true
    }

    /// Called only after the explicit request has been accepted for this same key.
    func erase(canonicalUserKey: String) throws {
        guard !canonicalUserKey.isEmpty, !unreadableState else { throw deletionStateError() }
        if states[canonicalUserKey]?.awaitingAcknowledgement != true {
            states[canonicalUserKey] = State(cutoff: Date(), isCloudKit: canonicalUserKey.hasPrefix("ck:"))
            try persist()
        }
        try resumeDeletion(for: canonicalUserKey)
    }

    /// Reapply after late imports; the cutoff survives Start over so newly
    /// created households remain usable while old cloud rows cannot reappear.
    func resumeDeletion(for canonicalUserKey: String) throws {
        guard !unreadableState else { throw deletionStateError() }
        guard var state = states[canonicalUserKey] else { return }
        let context = controller.viewContext
        let request = NSFetchRequest<HouseholdProfile>(entityName: "HouseholdProfile")
        request.predicate = NSPredicate(
            format: "canonicalUserKey == %@ AND (createdAt == nil OR createdAt <= %@)",
            canonicalUserKey, state.cutoff as NSDate
        )
        let households = try context.fetch(request)
        guard !households.isEmpty else {
            if state.lastEraseSavedAt == nil {
                state.lastEraseSavedAt = Date()
                states[canonicalUserKey] = state
                try persist()
            }
            return
        }
        let storeIDs = Set(households.compactMap { $0.objectID.persistentStore?.identifier })
        for household in households {
            // Keep the empty root as a tombstoned routing anchor. Deleting it
            // would leave no identity link for a child imported later by CK.
            for relationship in household.entity.relationshipsByName.values
                where relationship.isToMany && relationship.inverseRelationship?.name == "household" {
                let children = (household.value(forKey: relationship.name) as? NSSet)?.allObjects ?? []
                for case let child as NSManagedObject in children { context.delete(child) }
            }
            if household.deletedAt == nil { household.deletedAt = state.cutoff }
            if household.locale != nil { household.locale = nil }
            if household.timezone != nil { household.timezone = nil }
            if household.preferredUnits != nil { household.preferredUnits = nil }
            if household.servingsDefault != 2 { household.servingsDefault = 2 }
            if household.onboardingCompleted { household.onboardingCompleted = false }
        }
        // Child cascades cover recipe steps, groceries, session transcripts,
        // timers, and feedback. Roots retain only identity/deletion metadata.
        guard context.hasChanges else {
            // A prior save may have succeeded just before the marker write
            // failed or the process exited. The empty tombstoned graph is a
            // completed local erase, even though no second save is needed.
            if state.lastEraseSavedAt == nil {
                state.lastEraseSavedAt = Date()
                state.storeIdentifiers = Array(storeIDs)
                states[canonicalUserKey] = state
                try persist()
            }
            return
        }
        try save()
        state.lastEraseSavedAt = Date()
        state.cloudExportedAt = nil
        state.storeIdentifiers = Array(storeIDs)
        states[canonicalUserKey] = state
        try persist()
    }

    /// Acknowledge the local result, not an assertion of server/provider erasure.
    func acknowledgeDeletion(for canonicalUserKey: String) {
        guard var state = states[canonicalUserKey], state.lastEraseSavedAt != nil else { return }
        state.awaitingAcknowledgement = false
        states[canonicalUserKey] = state
        // Codable state contains only dates, booleans, strings. Keep the marker
        // blocking on an unexpected encoding/write failure rather than lose it.
        do { try persist() } catch { unreadableState = true }
    }

    /// A successful export must start after the deletion save and match its
    /// store. Earlier/in-flight or unrelated-store events prove nothing here.
    func observeExport(identifier: UUID, storeIdentifier: String, startedAt: Date, endedAt: Date?, succeeded: Bool) {
        if endedAt == nil {
            if startedAt >= identityResolvedAt { exportIdentities[identifier] = currentCanonicalKey }
            return
        }
        guard let key = exportIdentities.removeValue(forKey: identifier),
              key == currentCanonicalKey, succeeded, let endedAt else { return }
        recordSuccessfulExport(for: key, storeIdentifier: storeIdentifier, startedAt: startedAt, endedAt: endedAt)
    }

    func recordSuccessfulExport(for canonicalUserKey: String, storeIdentifier: String, startedAt: Date, endedAt: Date) {
        guard canonicalUserKey == currentCanonicalKey,
              var state = states[canonicalUserKey], state.isCloudKit,
              let savedAt = state.lastEraseSavedAt, startedAt >= savedAt,
              state.storeIdentifiers.contains(storeIdentifier) else { return }
        state.cloudExportedAt = endedAt
        states[canonicalUserKey] = state
        do { try persist() } catch { unreadableState = true }
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(states)
        defaults.set(data, forKey: Self.storageKey)
        guard defaults.synchronize() else { throw deletionStateError() }
    }

    private func deletionStateError() -> StirError {
        .coreData(underlying: NSError(
            domain: "Stir.HouseholdDeletion", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Deletion state could not be saved. Please try again."]
        ))
    }
}
