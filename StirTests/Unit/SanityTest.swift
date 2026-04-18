// SanityTest
//
// Placeholder test that verifies the test target compiles and links against
// the app target. Real unit tests land in commit 10.

import XCTest
@testable import Stir

final class SanityTest: XCTestCase {
    func test_sanity_compiles() {
        XCTAssertEqual(1 + 1, 2)
    }
}
