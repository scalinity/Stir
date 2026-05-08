// IdentityService
//
// Resolves the app's canonical_user_key on launch + on every CloudKit account
// status change. CLAUDE.md §"Canonical user key":
//
//   canonical_user_key = "ck:<userRecordName>"     when iCloud is available
//                      | "install:<keychainUUID>"  otherwise
//
// Design:
//   - Actor-isolated so concurrent resolve() calls are serialized.
//   - CloudKit access injected via `CloudKitAccountProviding` for tests.
//   - Keychain access injected via `KeychainStoring` for tests.
//   - `observeAccountChanges()` bridges `.CKAccountChanged` into an
//     AsyncStream of the freshly-resolved key. RootCoordinator consumes
//     this to re-drive the launch sequence if iCloud availability flips
//     mid-session.
//
// NEVER logs the raw canonical_user_key. Use `CanonicalKeyHash` everywhere
// a key identifies a user in operational output.

import CloudKit
import Foundation
import OSLog

/// Two-case identity discriminant. `stringValue` is the wire + bootstrap form.
enum CanonicalUserKey: Equatable, Hashable, Sendable {
    case cloudKit(recordName: String)
    case install(uuid: String)

    var stringValue: String {
        switch self {
        case .cloudKit(let recordName): return "ck:\(recordName)"
        case .install(let uuid):        return "install:\(uuid)"
        }
    }

    /// The raw CloudKit userRecordName when backed by CloudKit. Nil for
    /// install-keyed identities.
    var cloudKitRecordName: String? {
        if case let .cloudKit(recordName) = self { return recordName }
        return nil
    }

    var installationID: String? {
        if case let .install(uuid) = self { return uuid }
        return nil
    }

    var isCloudKit: Bool {
        if case .cloudKit = self { return true }
        return false
    }

    /// Round-trip from `stringValue` back into the typed enum. Used by
    /// `RootCoordinator.attemptFastPathLaunch` to reconstitute identity
    /// from the App Group cached value (written by previous launches via
    /// `SharedStorage.writeCanonicalUserKey`) without re-running the
    /// async `IdentityService.resolve()`. Returns nil for malformed
    /// inputs — caller treats those as cache miss.
    static func parse(_ string: String) -> CanonicalUserKey? {
        if string.hasPrefix("ck:") {
            let recordName = String(string.dropFirst(3))
            return recordName.isEmpty ? nil : .cloudKit(recordName: recordName)
        }
        if string.hasPrefix("install:") {
            let uuid = String(string.dropFirst(8))
            return uuid.isEmpty ? nil : .install(uuid: uuid)
        }
        return nil
    }
}

actor IdentityService {
    private let cloudKit: CloudKitAccountProviding
    private let keychain: KeychainStoring

    /// In-memory cache for the install UUID. Primed on first read (from
    /// Keychain or a freshly-minted value) and reused for the rest of the
    /// session so a keychain write failure mid-launch doesn't cause each
    /// subsequent `installationID()` call to mint a new UUID.
    private var cachedInstallUUID: String?

    init(
        cloudKit: CloudKitAccountProviding = CloudKitAccountProvider(),
        keychain: KeychainStoring = KeychainStorage.shared,
    ) {
        self.cloudKit = cloudKit
        self.keychain = keychain
    }

    /// Always-available install UUID. Read from Keychain if present,
    /// minted if absent. The bootstrap request ALWAYS carries this value
    /// (even when the user's canonical key is ck:<record>) so backend
    /// alias-forward can run when a CK user first appears.
    func installationID() -> String {
        installUUID()
    }

    /// Resolve the canonical key according to the CLAUDE.md rule.
    func resolve() async -> CanonicalUserKey {
        // --- CloudKit path ---
        do {
            let status = try await cloudKit.accountStatus()
            if status == .available {
                let recordID = try await cloudKit.userRecordID()
                let recordName = recordID.recordName
                Logger.identity.info("identity resolved: cloudkit (\(recordName.count, privacy: .public) chars)")
                return .cloudKit(recordName: recordName)
            }
            let description = statusDescription(status)
            Logger.identity.info("cloudkit status not available: \(description, privacy: .public)")
        } catch {
            Logger.identity.error("cloudkit resolution failed: \(error.localizedDescription, privacy: .public) — falling back to install UUID")
        }

        // --- Install-UUID path ---
        let uuid = installUUID()
        Logger.identity.info("identity resolved: install")
        return .install(uuid: uuid)
    }

    func cloudKitWebAuthToken(apiToken: String) async -> String? {
        guard !apiToken.isEmpty else { return nil }
        do {
            let token = try await cloudKit.webAuthToken(apiToken: apiToken)
            Logger.identity.info("cloudkit web auth token minted")
            return token
        } catch {
            Logger.identity.error("cloudkit web auth token failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Bridges `.CKAccountChanged` to an AsyncStream that yields a freshly
    /// resolved key every time iCloud availability flips. RootCoordinator
    /// observes this and may re-run the bootstrap sequence when a flip lands.
    nonisolated func observeAccountChanges() -> AsyncStream<CanonicalUserKey> {
        AsyncStream { continuation in
            let observer = NotificationCenter.default.addObserver(
                forName: .CKAccountChanged,
                object: nil,
                queue: nil,
            ) { _ in
                Task { [self] in
                    let key = await self.resolve()
                    continuation.yield(key)
                }
            }
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    // MARK: - Install UUID

    private func installUUID() -> String {
        if let cached = cachedInstallUUID { return cached }

        do {
            if let existing = try keychain.read(key: .installUUID) {
                cachedInstallUUID = existing
                return existing
            }
        } catch {
            // Read failure is not fatal — we'll mint a fresh UUID. But log so
            // repeated churn from a broken Keychain doesn't go unnoticed.
            Logger.identity.error("keychain read installUUID failed: \(error.localizedDescription, privacy: .public) — minting fresh UUID")
        }

        let fresh = UUID().uuidString
        // Cache BEFORE the write so a subsequent write failure doesn't cause
        // the next installationID() call to mint a second UUID and disagree
        // with the one this request already sent on the wire.
        cachedInstallUUID = fresh
        do {
            try keychain.write(fresh, key: .installUUID)
        } catch {
            // Write failure is bad but not crash-worthy — the in-memory cache
            // keeps this session consistent. Next cold start will retry the
            // write (and mint another UUID if Keychain is still broken).
            Logger.identity.error("keychain write installUUID failed: \(error.localizedDescription, privacy: .public)")
        }
        return fresh
    }

    // MARK: - Diagnostics

    private nonisolated func statusDescription(_ status: CKAccountStatus) -> String {
        switch status {
        case .couldNotDetermine:      return "couldNotDetermine"
        case .available:              return "available"
        case .restricted:             return "restricted"
        case .noAccount:              return "noAccount"
        case .temporarilyUnavailable: return "temporarilyUnavailable"
        @unknown default:             return "unknown"
        }
    }
}
