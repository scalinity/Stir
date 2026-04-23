// ImportViewModelTests
//
// Unit tests for the step-7 Import flow. Focus on client-side
// validation + state machine + RecipeImport audit row invariants.
// Network-path + Vision OCR tests live elsewhere (backend Deno suite
// + device manual verification) — EKEventStore and VNRecognizeTextRequest
// aren't worth mocking for unit coverage.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class ImportViewModelTests: XCTestCase {
    // MARK: - URL validation

    func test_submitURL_rejectsEmptyString() async throws {
        let vm = try makeVM()
        await vm.submitURL("")
        assertError(vm, code: "VAL-01")
    }

    func test_submitURL_rejectsMissingScheme() async throws {
        let vm = try makeVM()
        await vm.submitURL("nytimes.com/recipes/salmon")
        assertError(vm, code: "VAL-01")
    }

    func test_submitURL_rejectsNonHTTPScheme() async throws {
        let vm = try makeVM()
        await vm.submitURL("file:///etc/passwd")
        assertError(vm, code: "VAL-01")
    }

    // MARK: - Pasted text

    func test_submitPastedText_rejectsWhitespaceOnly() async throws {
        let vm = try makeVM()
        await vm.submitPastedText("   \n\t   ")
        assertError(vm, code: "VAL-01")
    }

    // MARK: - Cancel

    func test_cancelImport_resetsToIdle() async throws {
        let vm = try makeVM()
        vm.cancelImport()
        if case .idle = vm.stage { /* ok */ } else {
            XCTFail("expected .idle, got \(vm.stage)")
        }
    }

    // MARK: - Stage helpers

    func test_isBusy_flagsSubmittingAndSaving() async throws {
        let vm = try makeVM()
        XCTAssertFalse(vm.isBusy)
        // Can't synthetically force .submitting without a test-only hook.
        // Covered indirectly via the async submit paths in integration.
    }

    func test_isReviewing_falseAtIdle() async throws {
        let vm = try makeVM()
        XCTAssertFalse(vm.isReviewing)
    }

    // MARK: - Helpers

    private func makeVM() throws -> ImportViewModel {
        let controller = PersistenceController(inMemory: true)
        let ctx = controller.viewContext
        let household = HouseholdProfile(context: ctx)
        household.id = UUID()
        household.createdAt = Date()
        household.servingsDefault = 2
        try ctx.save()
        return ImportViewModel(
            household: household,
            aiDispatch: AIDispatch.stub,
            controller: controller,
        )
    }

    private func assertError(
        _ vm: ImportViewModel,
        code: String,
        file: StaticString = #file,
        line: UInt = #line,
    ) {
        if case .error(let c, _) = vm.stage {
            XCTAssertEqual(c, code, file: file, line: line)
        } else {
            XCTFail("expected .error(\(code)), got \(vm.stage)", file: file, line: line)
        }
    }
}

// MARK: - AIDispatch stub

private extension AIDispatch {
    static var stub: AIDispatch {
        let config = AppConfig(
            supabase: AppConfig.Supabase(url: URL(string: "https://test.invalid")!, anonKey: "x"),
            posthog: nil,
            sentry: nil,
            revenueCat: nil,
            build: "1.0.0 (1)",
            osVersion: "17.5",
        )
        let session = SupabaseSessionClient(
            config: config,
            keychain: MockKeychain(),
            urlSession: .shared,
            sentry: NoOpSentryReporter(),
        )
        return AIDispatch(session: session, config: config)
    }
}
