import XCTest

final class AppConfigurationTests: XCTestCase {
    func testSpeechFallbackHasPermissionExplanationInBuiltApp() {
        let description = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String
        XCTAssertFalse(description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func testBuiltAppRetainsCloudKitProofConfigurationKey() {
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "CloudKitAPIToken"))
    }

    func testBuiltAppRetainsRemoteNotificationBackgroundMode() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        XCTAssertTrue(modes?.contains("remote-notification") ?? false)
    }
}
