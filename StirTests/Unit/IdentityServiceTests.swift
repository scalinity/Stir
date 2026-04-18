// IdentityServiceTests
//
// Covers the CLAUDE.md rule:
//   canonical_user_key = "ck:<record>" when CloudKit .available,
//                      = "install:<uuid>" otherwise.
// Also: Keychain UUID persistence across service instances.

import CloudKit
import XCTest
@testable import Stir

final class IdentityServiceTests: XCTestCase {
    func test_resolve_returnsCloudKit_whenAccountAvailable() async throws {
        let cloudKit = MockCloudKitAccountProvider(.available(recordName: "_abc123record"))
        let keychain = MockKeychain()
        let service = IdentityService(cloudKit: cloudKit, keychain: keychain)

        let key = await service.resolve()

        XCTAssertEqual(key, .cloudKit(recordName: "_abc123record"))
        XCTAssertEqual(key.stringValue, "ck:_abc123record")
        XCTAssertTrue(key.isCloudKit)
    }

    func test_resolve_returnsInstall_whenAccountNotAvailable() async throws {
        let cloudKit = MockCloudKitAccountProvider(.status(.noAccount))
        let keychain = MockKeychain()
        let service = IdentityService(cloudKit: cloudKit, keychain: keychain)

        let key = await service.resolve()

        guard case .install(let uuid) = key else {
            return XCTFail("expected install: got \(key)")
        }
        XCTAssertNotNil(UUID(uuidString: uuid))
        XCTAssertTrue(key.stringValue.hasPrefix("install:"))
    }

    func test_resolve_returnsInstall_whenAccountStatusRestricted() async throws {
        let cloudKit = MockCloudKitAccountProvider(.status(.restricted))
        let keychain = MockKeychain()
        let service = IdentityService(cloudKit: cloudKit, keychain: keychain)

        let key = await service.resolve()
        guard case .install = key else {
            return XCTFail("restricted should fall back to install:")
        }
    }

    func test_resolve_returnsInstall_whenCloudKitThrows() async throws {
        let cloudKit = MockCloudKitAccountProvider(.failure(
            NSError(domain: "Test", code: 500, userInfo: nil),
        ))
        let keychain = MockKeychain()
        let service = IdentityService(cloudKit: cloudKit, keychain: keychain)

        let key = await service.resolve()
        guard case .install = key else {
            return XCTFail("error should fall back to install:")
        }
    }

    func test_installUUID_isStableAcrossCalls() async throws {
        let cloudKit = MockCloudKitAccountProvider(.status(.noAccount))
        let keychain = MockKeychain()
        let service = IdentityService(cloudKit: cloudKit, keychain: keychain)

        let key1 = await service.resolve()
        let key2 = await service.resolve()
        XCTAssertEqual(key1, key2)
    }

    func test_installUUID_persistsAcrossServiceInstances() async throws {
        let cloudKit = MockCloudKitAccountProvider(.status(.noAccount))
        let keychain = MockKeychain()

        let first = await IdentityService(cloudKit: cloudKit, keychain: keychain).resolve()
        let second = await IdentityService(cloudKit: cloudKit, keychain: keychain).resolve()

        XCTAssertEqual(first, second)
    }

    func test_installationID_alwaysReturnsUUID_evenWhenCloudKitAvailable() async throws {
        let cloudKit = MockCloudKitAccountProvider(.available(recordName: "_recordA"))
        let keychain = MockKeychain()
        let service = IdentityService(cloudKit: cloudKit, keychain: keychain)

        let installID = await service.installationID()
        XCTAssertNotNil(UUID(uuidString: installID))

        // The install UUID exists in Keychain (was minted on first ask).
        XCTAssertNotNil(try keychain.read(key: .installUUID))
    }
}
