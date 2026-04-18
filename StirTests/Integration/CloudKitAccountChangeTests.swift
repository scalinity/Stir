// CloudKitAccountChangeTests
//
// Posts `.CKAccountChanged` from the test and asserts the AsyncStream
// re-emits with the current mock state.

import CloudKit
import Foundation
import XCTest
@testable import Stir

final class CloudKitAccountChangeTests: XCTestCase {
    func test_accountChange_reResolvesIdentity() async throws {
        let cloudKit = MockCloudKitAccountProvider(.status(.noAccount))
        let keychain = MockKeychain()
        let service = IdentityService(cloudKit: cloudKit, keychain: keychain)

        let stream = service.observeAccountChanges()
        var iterator = stream.makeAsyncIterator()

        // Flip the mock to "available" and post the notification.
        cloudKit.setBehavior(.available(recordName: "_newRecord"))
        NotificationCenter.default.post(name: .CKAccountChanged, object: nil)

        // AsyncStream should yield a new resolved key within a few hundred ms.
        let emitted: CanonicalUserKey? = try await withTimeout(seconds: 2) {
            await iterator.next()
        }

        XCTAssertNotNil(emitted)
        XCTAssertTrue(emitted?.isCloudKit ?? false)
        XCTAssertEqual(emitted?.cloudKitRecordName, "_newRecord")
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @Sendable @escaping () async -> T?,
    ) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = try await group.next()
            group.cancelAll()
            return first ?? nil
        }
    }
}
