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

    // MARK: - Persist imported recipe

    func test_buildRecipePlan_marksImportedPlanSavedForSavedMeals() throws {
        let fixture = try makeFixture()
        let planID = try fixture.vm.buildRecipePlan(sampleImportedRecipe(), source: .pastedText)
        try fixture.controller.save()

        let entries = try CookingSessionRepository(controller: fixture.controller)
            .savedMealEntries(for: fixture.household)
        XCTAssertEqual(entries.map(\.id), [planID])
        XCTAssertEqual(entries.first?.title, "Weeknight Tomato Pasta")
        XCTAssertEqual(entries.first?.plan?.isSaved, true)
        XCTAssertEqual(entries.first?.plan?.isFavorite, false)
    }

    // MARK: - Helpers

    private struct Fixture {
        let vm: ImportViewModel
        let controller: PersistenceController
        let household: HouseholdProfile
    }

    private func makeFixture() throws -> Fixture {
        let controller = PersistenceController(inMemory: true)
        let ctx = controller.viewContext
        let household = HouseholdProfile(context: ctx)
        household.id = UUID()
        household.createdAt = Date()
        household.servingsDefault = 2
        try ctx.save()
        // SCA-190: both `importRepo` and `controller` are required init
        // params (no defaults). They MUST share the same controller —
        // diverging them is the SCA-179 footgun. Tests passing two
        // independent values would have to do so deliberately and
        // visibly here, not via a defaulted-arg silent fall-through.
        let vm = ImportViewModel(
            household: household,
            aiDispatch: AIDispatch.stub,
            importRepo: RecipeImportRepository(controller: controller),
            controller: controller,
        )
        return Fixture(vm: vm, controller: controller, household: household)
    }

    private func makeVM() throws -> ImportViewModel {
        try makeFixture().vm
    }

    private func sampleImportedRecipe() -> RecipeImportResponse.ImportedRecipe {
        RecipeImportResponse.ImportedRecipe(
            title: "Weeknight Tomato Pasta",
            servings: 2,
            estimatedMinutes: 25,
            ingredients: [
                .init(
                    displayName: "spaghetti",
                    canonicalSlug: "spaghetti",
                    amountText: "8 oz",
                    group: nil,
                ),
            ],
            steps: [
                .init(
                    stepNumber: 1,
                    instructionText: "Boil the pasta until al dente.",
                    timerSeconds: 600,
                    cautionTags: nil,
                ),
            ],
            parseQuality: .high,
            editHints: nil,
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

@MainActor
final class ImportRecoverySafetyTests: XCTestCase {
    func test_highConfidenceStepAllergenBlocksSaveAndChecksCurrentRules() async throws {
        let fixture = try makeFixture()
        await fixture.vm.submitPastedText("rice recipe")
        XCTAssertEqual(fixture.vm.stageKind, .queued)
        await fixture.vm.resume(importID: fixture.id)
        XCTAssertEqual(fixture.vm.stageKind, .review)
        XCTAssertTrue(fixture.vm.dietaryConflicts.isEmpty)
        let rule = DietaryRule(context: fixture.controller.viewContext)
        rule.id = UUID(); rule.household = fixture.household
        rule.value = "peanut"; rule.typedKind = .allergy
        rule.typedSeverity = .hard; rule.isActive = true
        XCTAssertFalse(fixture.vm.dietaryConflicts.isEmpty)
        await fixture.vm.confirmAndSave()
        XCTAssertEqual(fixture.vm.stageKind, .review)
        let plans = NSFetchRequest<RecipePlan>(entityName: "RecipePlan")
        XCTAssertEqual(try fixture.controller.viewContext.count(for: plans), 0)
    }

    func test_relaunchResultRecoverySavesExactlyOnePlanAndRepeatedNotificationOpensIt() async throws {
        let fixture = try makeFixture()
        await fixture.vm.submitPastedText("rice recipe")
        let reopened = makeVM(controller: fixture.controller, household: fixture.household, id: fixture.id)
        await reopened.resume()
        XCTAssertEqual(reopened.stageKind, .review)
        await reopened.confirmAndSave()
        await reopened.confirmAndSave()
        let tapped = makeVM(controller: fixture.controller, household: fixture.household, id: fixture.id)
        await tapped.resume(importID: fixture.id)
        XCTAssertEqual(tapped.stageKind, .saved)
        let plans = NSFetchRequest<RecipePlan>(entityName: "RecipePlan")
        XCTAssertEqual(try fixture.controller.viewContext.count(for: plans), 1)
    }

    func test_importDeepLinkAndDeniedNotificationsDoNotAffectRecovery() async throws {
        let fixture = try makeFixture()
        let url = URL(string: "stir://import/\(fixture.id)")!
        XCTAssertEqual(StirDeepLink.parse(url), .importResult(importID: fixture.id))
        let delegate = StirNotificationDelegate(telemetry: PostHogClient(testingOnly: true))
        delegate.routeImportCompletion(userInfo: ["deep_link": url.absoluteString])
        XCTAssertEqual(delegate.consumePendingImportID(), fixture.id)
        XCTAssertNil(delegate.consumePendingImportID())
        // No notification permission or delegate is needed for foreground/reopen.
        await fixture.vm.submitPastedText("rice recipe")
        await fixture.vm.resume(importID: fixture.id)
        XCTAssertEqual(fixture.vm.stageKind, .review)
    }

    func test_expiredResultIsExplicitAndDoesNotSubmitAgain() async throws {
        let fixture = try makeFixture()
        await fixture.vm.submitPastedText("rice recipe")
        let reopened = ImportViewModel(
            household: fixture.household, aiDispatch: .stub,
            importRepo: RecipeImportRepository(controller: fixture.controller), controller: fixture.controller,
            resultLoader: { id in
                RecipeImportResponse(importID: id, status: .expired, recipe: nil, retryCount: 0, promptVersion: "1", asyncJobID: nil)
            },
            submitter: { _ in XCTFail("Recovery must not resubmit"); throw CancellationError() }
        )
        await reopened.resume()
        XCTAssertEqual(reopened.stageKind, .error)
    }

    private struct Fixture {
        let vm: ImportViewModel
        let controller: PersistenceController
        let household: HouseholdProfile
        let initialID: UUID
        @MainActor var id: UUID {
            (try? RecipeImportRepository(controller: controller).recent(for: household).first?.id) ?? initialID
        }
    }

    private func makeFixture() throws -> Fixture {
        let controller = PersistenceController(inMemory: true)
        let household = HouseholdProfile(context: controller.viewContext)
        household.id = UUID(); household.createdAt = Date(); household.servingsDefault = 2
        try controller.save()
        let id = UUID()
        return Fixture(vm: makeVM(controller: controller, household: household, id: id), controller: controller, household: household, initialID: id)
    }

    private func makeVM(controller: PersistenceController, household: HouseholdProfile, id: UUID) -> ImportViewModel {
        ImportViewModel(
            household: household, aiDispatch: .stub,
            importRepo: RecipeImportRepository(controller: controller), controller: controller,
            resultLoader: { importID in
                let recipe = RecipeImportResponse.ImportedRecipe(
                    title: "Rice", servings: 2, estimatedMinutes: 10,
                    ingredients: [.init(displayName: "rice", canonicalSlug: "rice", amountText: "1 cup", group: nil)],
                    steps: [.init(stepNumber: 1, instructionText: "Top with crushed peanuts.", timerSeconds: nil, cautionTags: nil)],
                    parseQuality: .high, editHints: nil
                )
                return RecipeImportResponse(importID: importID, status: .completed, recipe: recipe, retryCount: 0, promptVersion: "1", asyncJobID: nil)
            },
            submitter: { request in
                RecipeImportResponse(importID: request.importID, status: .queued, recipe: nil, retryCount: 0, promptVersion: "1", asyncJobID: id.uuidString)
            }
        )
    }
}
