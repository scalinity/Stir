// SubstitutionRepositoryTests
//
// Exercises persist + recordDecision + applyAcceptedSwap semantics
// directly against an in-memory PersistenceController. These tests
// don't depend on the AIDispatch network round-trip — VM-level reject
// retry coverage lives outside the unit scope (observation 490, mirror
// of the SubstitutionSheetViewModelTests scope rule).
//
// applyAcceptedSwap is the load-bearing piece for fixing bugs where:
//   - the substitution picker re-shows the original ingredient name
//     after a successful accept (bug #3 in the user report)
//   - the voice context's `remainingIngredients` keeps referencing
//     the swapped-out ingredient
//   - any future grocery export of the recipe lists the wrong item
// All three downstream consumers read RecipeIngredient.displayName,
// so mutating the Core Data row is the smallest fix that makes them
// all see the swap.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class SubstitutionRepositoryTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var recipePlan: RecipePlan!
    private var session: CookingSession!
    private var repo: SubstitutionRepository!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        let houseRepo = HouseholdProfileRepository(controller: controller)
        household = try houseRepo.ensureHouseholdProfile(for: "install:test-\(UUID().uuidString)")
        recipePlan = try makeRecipePlan(household: household, ingredientNames: ["dried pasta", "tomato"])
        session = try CookingSessionRepository(controller: controller)
            .createSession(on: household, for: recipePlan, entryPoint: .solve)
        repo = SubstitutionRepository(controller: controller)
    }

    // MARK: - applyAcceptedSwap on picker-selected events

    func test_applyAcceptedSwap_picker_mutatesDisplayName() throws {
        let pasta = try XCTUnwrap(recipePlan.ingredientArray.first { $0.displayName == "dried pasta" })
        let event = try persistPickerEvent(on: pasta)

        try repo.applyAcceptedSwap(event, substitutionText: "rice noodles", amountConversion: nil)

        XCTAssertEqual(pasta.displayName, "rice noodles",
                       "displayName must reflect the swap so substitution picker shows the new name on re-open")
    }

    func test_applyAcceptedSwap_picker_withAmountConversion_mutatesAmountText() throws {
        let pasta = try XCTUnwrap(recipePlan.ingredientArray.first { $0.displayName == "dried pasta" })
        pasta.amountText = "12 oz"
        try controller.save()
        let event = try persistPickerEvent(on: pasta)

        try repo.applyAcceptedSwap(
            event,
            substitutionText: "rice noodles",
            amountConversion: "8 oz",
        )

        XCTAssertEqual(pasta.amountText, "8 oz")
    }

    func test_applyAcceptedSwap_picker_nilAmountConversion_preservesAmountText() throws {
        // When the model declines an amount conversion (substitution at the
        // same ratio), preserve the original amount so the user's mental
        // model of "use the same amount" stays accurate.
        let pasta = try XCTUnwrap(recipePlan.ingredientArray.first { $0.displayName == "dried pasta" })
        pasta.amountText = "12 oz"
        try controller.save()
        let event = try persistPickerEvent(on: pasta)

        try repo.applyAcceptedSwap(event, substitutionText: "rice noodles", amountConversion: nil)

        XCTAssertEqual(pasta.amountText, "12 oz")
    }

    func test_applyAcceptedSwap_picker_blankAmountConversion_preservesAmountText() throws {
        // Whitespace-only amountConversion is treated as nil — same
        // skip-when-blank discipline as the wire encoder.
        let pasta = try XCTUnwrap(recipePlan.ingredientArray.first { $0.displayName == "dried pasta" })
        pasta.amountText = "12 oz"
        try controller.save()
        let event = try persistPickerEvent(on: pasta)

        try repo.applyAcceptedSwap(event, substitutionText: "rice noodles", amountConversion: "   ")

        XCTAssertEqual(pasta.amountText, "12 oz")
    }

    func test_applyAcceptedSwap_picker_nilsCanonicalSlug() throws {
        // The slug encoded the original ingredient's identity (e.g.
        // "pasta-dried"); after a swap to "rice noodles" the slug is
        // stale. Nil it so consumers don't make decisions based on a
        // mismatched slug.
        let pasta = try XCTUnwrap(recipePlan.ingredientArray.first { $0.displayName == "dried pasta" })
        pasta.canonicalIngredientSlug = "pasta-dried"
        try controller.save()
        let event = try persistPickerEvent(on: pasta)

        try repo.applyAcceptedSwap(event, substitutionText: "rice noodles", amountConversion: nil)

        XCTAssertNil(pasta.canonicalIngredientSlug)
    }

    func test_applyAcceptedSwap_picker_pickerWouldShowSwappedNameOnReOpen() throws {
        // Regression for bug #3: substitution sheet's picker reads
        // recipePlan.ingredientArray.compactMap { ($0.id, $0.displayName) }.
        // After applyAcceptedSwap, that projection must yield the new name.
        let pasta = try XCTUnwrap(recipePlan.ingredientArray.first { $0.displayName == "dried pasta" })
        let event = try persistPickerEvent(on: pasta)

        try repo.applyAcceptedSwap(event, substitutionText: "rice noodles", amountConversion: nil)

        let pickerLabels = recipePlan.ingredientArray.compactMap { ing -> String? in
            guard let name = ing.displayName, !name.isEmpty else { return nil }
            return name
        }
        XCTAssertTrue(pickerLabels.contains("rice noodles"),
                      "Picker must show swapped name; got: \(pickerLabels)")
        XCTAssertFalse(pickerLabels.contains("dried pasta"),
                       "Picker must NOT show original name after swap; got: \(pickerLabels)")
    }

    // MARK: - applyAcceptedSwap on free-text events

    func test_applyAcceptedSwap_freeTextEvent_isNoOp() throws {
        // Free-text events have no recipeIngredient FK — there's nothing
        // to mutate. The SubstitutionEvent itself captures the swap for
        // those cases; the recipe stays unchanged.
        let pasta = try XCTUnwrap(recipePlan.ingredientArray.first { $0.displayName == "dried pasta" })
        let originalName = pasta.displayName
        let originalAmount = pasta.amountText

        let freeTextEvent = try repo.persist(SubstitutionRepository.PersistInput(
            subEventId: UUID(),
            session: session,
            ingredient: nil,
            freeTextName: "my blender broke",
            step: nil,
            userProblemText: "blender died mid-recipe",
            modelSuggestionText: "use a fork to mash",
            hardConstraintCheckPassed: true,
        ))

        // Should not throw, should not touch any ingredient.
        try repo.applyAcceptedSwap(
            freeTextEvent,
            substitutionText: "use a fork to mash",
            amountConversion: nil,
        )

        XCTAssertEqual(pasta.displayName, originalName)
        XCTAssertEqual(pasta.amountText, originalAmount)
    }

    // MARK: - History / event integrity after swap

    func test_applyAcceptedSwap_preservesSubstitutionEventForAudit() throws {
        // The mutation is on RecipeIngredient — the SubstitutionEvent must
        // remain intact so the audit trail (what was missing, what was
        // suggested, what the user accepted) survives the swap.
        let pasta = try XCTUnwrap(recipePlan.ingredientArray.first { $0.displayName == "dried pasta" })
        let event = try persistPickerEvent(on: pasta)
        try repo.recordDecision(event, accepted: true, acceptedAlternativeText: "rice noodles")

        try repo.applyAcceptedSwap(event, substitutionText: "rice noodles", amountConversion: nil)

        XCTAssertEqual(event.acceptedBool, true)
        XCTAssertEqual(event.acceptedAlternativeText, "rice noodles")
        XCTAssertEqual(event.modelSuggestionText, "rice noodles")
        XCTAssertIdentical(event.recipeIngredient, pasta,
                           "FK must still resolve to the (now-swapped) ingredient row")
    }

    // MARK: - applyStepRewrite (SCA-432)

    func test_applyStepRewrite_replacesInstructionText() throws {
        let step = try makeStep(
            on: recipePlan,
            number: 1,
            instructionText: "Mix flour, a pinch of salt, and water to form a soft dough.",
        )
        let rewritten = "Combine 1 cup of finely crushed tortilla chips with a pinch of salt and water to form a soft dough."
        try repo.applyStepRewrite(step: step, rewrittenText: rewritten)
        XCTAssertEqual(step.instructionText, rewritten)
    }

    func test_applyStepRewrite_trimsWhitespace() throws {
        let step = try makeStep(
            on: recipePlan,
            number: 1,
            instructionText: "Original.",
        )
        try repo.applyStepRewrite(step: step, rewrittenText: "  rewritten step.  \n")
        XCTAssertEqual(step.instructionText, "rewritten step.",
                       "leading/trailing whitespace must not bleed into the card render")
    }

    func test_applyStepRewrite_emptyRewrittenText_isNoOp() throws {
        // Defense-in-depth: a degenerate model response (empty string) must
        // never blank out the step. The model call already logs its outcome;
        // this is the persist-boundary guard.
        let step = try makeStep(
            on: recipePlan,
            number: 1,
            instructionText: "Original prose.",
        )
        try repo.applyStepRewrite(step: step, rewrittenText: "")
        XCTAssertEqual(step.instructionText, "Original prose.")
    }

    func test_applyStepRewrite_whitespaceOnlyRewrittenText_isNoOp() throws {
        let step = try makeStep(
            on: recipePlan,
            number: 1,
            instructionText: "Original prose.",
        )
        try repo.applyStepRewrite(step: step, rewrittenText: "   \n\t  ")
        XCTAssertEqual(step.instructionText, "Original prose.")
    }

    // MARK: - Helpers

    private func makeStep(
        on plan: RecipePlan,
        number: Int,
        instructionText: String,
    ) throws -> RecipeStep {
        let context = controller.viewContext
        let step = RecipeStep(context: context)
        step.id = UUID()
        step.recipePlan = plan
        step.stepNumber = Int16(number)
        step.sortOrder = Int16(number)
        step.instructionText = instructionText
        try controller.save()
        return step
    }

    private func persistPickerEvent(on ingredient: RecipeIngredient) throws -> SubstitutionEvent {
        try repo.persist(SubstitutionRepository.PersistInput(
            subEventId: UUID(),
            session: session,
            ingredient: ingredient,
            freeTextName: nil,
            step: nil,
            userProblemText: "out of dried pasta",
            modelSuggestionText: "rice noodles",
            hardConstraintCheckPassed: true,
        ))
    }

    private func makeRecipePlan(household: HouseholdProfile, ingredientNames: [String]) throws -> RecipePlan {
        let context = controller.viewContext
        let plan = RecipePlan(context: context)
        plan.id = UUID()
        plan.household = household
        plan.title = "Substitution Repo Test"
        plan.servings = 2
        plan.estimatedMinutes = 25
        plan.typedOrigin = .ai
        plan.createdAt = Date()
        plan.updatedAt = Date()

        for (idx, name) in ingredientNames.enumerated() {
            let ing = RecipeIngredient(context: context)
            ing.id = UUID()
            ing.recipePlan = plan
            ing.displayName = name
            ing.sortOrder = Int16(idx)
            ing.amountText = "1 cup"
            ing.isOptional = false
        }
        try controller.save()
        return plan
    }
}
