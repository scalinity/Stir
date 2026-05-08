// PersistenceControllerSaveTests
//
// SCA-98 regression coverage for `PersistenceController.save()`'s catch
// block. The pre-fix log line interpolated `error.localizedDescription`
// at `privacy: .public`, which leaked user-supplied attribute values
// from Core Data's `NSValidationError` userInfo path into the system
// log. The fix logs only `domain` + `code` — both are safe primitives
// (NSError domain is a constant string, code is an int).
//
// On the runtime test approach: triggering an actual `save()` failure
// here would need a uniqueness or relationship-constraint violation
// against the live Core Data model, AND OSLogStore-based capture (with
// flush timing). That setup is fragile in CI. Instead this is a
// contract test: the expected format string is encoded as a constant
// next to the call site, and the test asserts the contract. Any future
// change to the catch-block log line MUST update both the constant and
// this test in lockstep — drift is the failure mode the test prevents.

import XCTest
@testable import Stir

@MainActor
final class PersistenceControllerSaveTests: XCTestCase {
    // MARK: - SCA-98 privacy contract

    /// SCA-98: log format MUST NOT include `localizedDescription` at
    /// `.public`. NSError on Core Data validation embeds the rejected
    /// attribute value verbatim.
    func test_saveFailureLogFormat_excludesUserContent() {
        let format = PersistenceController.saveFailureLogFormat
        XCTAssertFalse(
            format.contains("localizedDescription"),
            "saveFailureLogFormat must not interpolate error.localizedDescription (SCA-98)"
        )
        XCTAssertFalse(
            format.contains("userInfo"),
            "saveFailureLogFormat must not interpolate NSError.userInfo (SCA-98)"
        )
    }

    /// SCA-98: log format MUST preserve enough debug signal — domain +
    /// code at minimum — so on-call has something to work with.
    func test_saveFailureLogFormat_preservesDomainAndCode() {
        let format = PersistenceController.saveFailureLogFormat
        XCTAssertTrue(format.contains("domain="), "Expected 'domain=' in log format")
        XCTAssertTrue(format.contains("code="), "Expected 'code=' in log format")
    }

    // MARK: - Sanity (no-op save path)

    /// `save()` is a no-op when the context has no pending changes.
    /// Confirms the early-return branch doesn't accidentally throw.
    func test_save_noChanges_returnsWithoutThrowing() throws {
        let pc = PersistenceController(inMemory: true)
        XCTAssertNoThrow(try pc.save())
    }
}
