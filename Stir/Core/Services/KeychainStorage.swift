// KeychainStorage
//
// Thin `SecItem*` wrapper used by IdentityService (install UUID),
// SupabaseSessionClient (session JWT), and EntitlementService (last-known-good
// entitlement snapshot for the 24h offline grace window).
//
// CLAUDE.md §"What NOT to do by default" mandates Keychain over UserDefaults
// for anything mildly sensitive. Every key here gets a deterministic
// account/service pairing so uninstall-and-reinstall clears everything.
//
// Access group is intentionally unset — step 7 (extensions) will introduce a
// shared access group if Share Extension or Widgets need to read the session.
// Default group is per-app, scoped by bundle ID.
//
// TODO(SCA-share-ext): V2→V3 entitlement-snapshot erase paths in
// `EntitlementService.restoreFromCachedSnapshotIfFresh` use the
// `kSecAttrAccessGroup`-default group. When the share extension target
// lands and introduces a shared access group, the erase needs to be
// re-run scoped per-access-group (default + shared) so the legacy V2
// blob in the shared group doesn't strand and silently re-hydrate the
// extension's cache. File the follow-up SCA-* ticket alongside the
// share-extension landing PR.

import Foundation
import Security
import OSLog

/// Abstraction over Keychain access so tests can swap in an in-memory double.
protocol KeychainStoring: Sendable {
    func read(key: KeychainKey) throws -> String?
    func write(_ value: String, key: KeychainKey) throws
    func delete(key: KeychainKey) throws
}

/// Typed Keychain slot. Service + account tuple is the Keychain-level primary key.
struct KeychainKey: Hashable, Sendable {
    let service: String
    let account: String
}

extension KeychainKey {
    /// Default service scope — derived from the bundle identifier so multiple
    /// apps installed side-by-side (e.g. `com.scalinity.stir.dev` and
    /// `com.scalinity.stir`) don't collide.
    private static var defaultService: String {
        Bundle.main.bundleIdentifier ?? "com.scalinity.stir"
    }

    /// The keychain-backed install UUID used when CloudKit identity is
    /// unavailable. Accessibility is `AfterFirstUnlockThisDeviceOnly` (see
    /// the write path below), so the value is NOT synced via iCloud
    /// Keychain and does NOT follow the user to a new device. A restored
    /// iCloud backup will present as a fresh install; once the user signs
    /// into iCloud, the ck:<record> alias-forward takes over and the
    /// install-keyed row merges forward. Intentional — the session JWT in
    /// this same Keychain is also ThisDeviceOnly, and bundling the two
    /// keeps device-migration behavior consistent.
    static var installUUID: KeychainKey {
        KeychainKey(service: defaultService, account: "install_uuid")
    }

    /// Current session JWT from /v1/session/bootstrap. TTL 24h; refreshed by
    /// SupabaseSessionClient on AUTH-01 or 24h-expired reads.
    static var sessionJWT: KeychainKey {
        KeychainKey(service: defaultService, account: "session_jwt")
    }

    /// Last-known-good entitlement snapshot (JSON). Used within a 24h grace
    /// window when bootstrap fails.
    ///
    /// v2 — step 5 bumped the shape (renamed `showBillingGraceBanner` →
    /// `billingRetryBanner` to match the backend field). Old v1 bytes under
    /// `entitlement_snapshot` fail to decode against the new struct, which
    /// would silently drop the grace window on first launch after update;
    /// bumping the account name instead gives us an explicit cutover and a
    /// one-time delete of the legacy slot on service init (see
    /// `EntitlementService.restoreFromCachedSnapshotIfFresh`).
    ///
    /// v3 — SCA-207 sunset. `BootstrapResponse.Entitlements.standingPantryCap`
    /// flipped from `Int?` to `Int`, so `PersistedSnapshot.serverStandingPantryCap`
    /// must too. A v2 snapshot decoded against the v3 struct would carry
    /// nil through `optional → required` and crash; bump the slot and
    /// delete v2 on init.
    ///
    /// SCA-301 W11 + W12 reversal: the wire field was demoted back to
    /// `Int?` for boundary-level defensive decoding, and
    /// `restoreFromCachedSnapshotIfFresh` now CROSS-DECODES v2 →
    /// translates → persists v3 → drops v2 rather than blindly
    /// pre-deleting v2. A user upgrading offline (V2 bytes on disk,
    /// V3 not yet written, no successful post-upgrade bootstrap) no
    /// longer falls back to Free defaults mid-grace. This slot stays
    /// the live read/write target.
    static var entitlementSnapshotV3: KeychainKey {
        KeychainKey(service: defaultService, account: "entitlement_snapshot_v3")
    }

    /// Legacy v2 slot. SCA-301 W12: kept readable for cross-decode
    /// fallback in `EntitlementService.restoreFromCachedSnapshotIfFresh`;
    /// only deleted post-translation to v3 (or on stale/decode-fail).
    /// Never written by current code.
    // TODO(post-v1.1): retire entitlementSnapshotV2 slot — once all
    // production users have a V3 snapshot persisted, the cross-decode
    // path in `restoreFromCachedSnapshotIfFresh` and this key both
    // become dead weight. Drop together; never write V2 in the meantime.
    static var entitlementSnapshotV2: KeychainKey {
        KeychainKey(service: defaultService, account: "entitlement_snapshot_v2")
    }

    /// Legacy v1 slot. Deleted on EntitlementService init; never written.
    static var entitlementSnapshotLegacyV1: KeychainKey {
        KeychainKey(service: defaultService, account: "entitlement_snapshot")
    }
}

enum KeychainStorageError: Error, Sendable, Equatable {
    case osStatus(OSStatus)
    case dataCorrupted
}

struct KeychainStorage: KeychainStoring {
    static let shared = KeychainStorage()

    func read(key: KeychainKey) throws -> String? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: key.service,
            kSecAttrAccount: key.account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]

        var result: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &result) { ptr in
            SecItemCopyMatching(query as CFDictionary, ptr)
        }
        _ = query // silence unused in Release-only builds

        switch status {
        case errSecSuccess:
            guard
                let data = result as? Data,
                let string = String(data: data, encoding: .utf8)
            else {
                throw KeychainStorageError.dataCorrupted
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            Logger.identity.error("keychain read failed, OSStatus=\(status, privacy: .public)")
            throw KeychainStorageError.osStatus(status)
        }
    }

    func write(_ value: String, key: KeychainKey) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainStorageError.dataCorrupted
        }

        // Upsert: try update first; if not present, add.
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: key.service,
            kSecAttrAccount: key.account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            // Items are accessible after first unlock, never on locked device
            // or backup to another device. kSecAttrAccessibleAfterFirstUnlock
            // is the standard pattern for session tokens that must survive
            // app relaunches but not device-to-device migration.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary,
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            for (k, v) in attributes { addQuery[k] = v }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            switch addStatus {
            case errSecSuccess:
                return
            case errSecDuplicateItem:
                // TOCTOU: between the update-not-found and add, another
                // caller (test parallelism, extension, or reinstall replay)
                // wrote the item. Fall back to update — which will now
                // succeed against the row we just raced with. If it STILL
                // fails, surface the error honestly.
                let retryStatus = SecItemUpdate(
                    baseQuery as CFDictionary,
                    attributes as CFDictionary,
                )
                if retryStatus != errSecSuccess {
                    Logger.identity.error("keychain add→update retry failed, OSStatus=\(retryStatus, privacy: .public)")
                    throw KeychainStorageError.osStatus(retryStatus)
                }
            default:
                Logger.identity.error("keychain add failed, OSStatus=\(addStatus, privacy: .public)")
                throw KeychainStorageError.osStatus(addStatus)
            }
        default:
            Logger.identity.error("keychain update failed, OSStatus=\(updateStatus, privacy: .public)")
            throw KeychainStorageError.osStatus(updateStatus)
        }
    }

    func delete(key: KeychainKey) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: key.service,
            kSecAttrAccount: key.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            // SCA-313 S30: many callers use `try? keychain.delete(...)`
            // because a missing-slot is the common shape on first launch.
            // Real Keychain failures (OSStatus != errSecItemNotFound)
            // shouldn't be silently swallowed — log at `.warning` so
            // they show up in the unified log even when the caller
            // discards the throw. The typed error still propagates for
            // callers that DON'T use `try?` (e.g. test fixtures).
            Logger.identity.warning(
                "keychain delete failed (service=\(key.service, privacy: .public) account=\(key.account, privacy: .public)), OSStatus=\(status, privacy: .public)",
            )
            throw KeychainStorageError.osStatus(status)
        }
    }
}
