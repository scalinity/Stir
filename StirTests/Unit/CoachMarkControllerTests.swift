// CoachMarkControllerTests
//
// Drives the per-screen coach-mark controller through the lifecycle
// the presenter modifier composes: start → advance → optional
// skip / complete-action / suspend (disappear-driven). Each test runs
// against an isolated UserDefaults suite so persistence semantics are
// real (manager flips the durable flag on resolve) without leaking
// into `.standard`.

import XCTest
@testable import Stir

final class CoachMarkControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var manager: TutorialManager!
    private var suiteName: String!

    @MainActor
    override func setUp() {
        super.setUp()
        suiteName = "test.coachmark.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        manager = TutorialManager(defaults: defaults, sentry: NoOpSentryReporter())
    }

    @MainActor
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        manager = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Lifecycle

    @MainActor
    func test_freshController_isNotPresenting() {
        let controller = CoachMarkController(
            key: .scanCapture,
            steps: ScanCaptureCoachMarks.steps,
            manager: manager,
        )
        XCTAssertFalse(controller.isPresenting)
        XCTAssertNil(controller.currentStep)
    }

    @MainActor
    func test_start_setsPresentingAndExposesFirstStep() {
        let controller = CoachMarkController(
            key: .scanCapture,
            steps: ScanCaptureCoachMarks.steps,
            manager: manager,
        )
        controller.start()
        XCTAssertTrue(controller.isPresenting)
        XCTAssertEqual(controller.currentIndex, 0)
        XCTAssertEqual(controller.currentStep?.id, ScanCaptureCoachMarks.steps.first?.id)
    }

    @MainActor
    func test_start_isIdempotentWhilePresenting() {
        let controller = CoachMarkController(
            key: .scanCapture,
            steps: ScanCaptureCoachMarks.steps,
            manager: manager,
        )
        controller.start()
        controller.advance()
        let advancedIndex = controller.currentIndex
        controller.start()
        // Re-calling start() while already presenting must NOT reset
        // back to step 0 — that would mid-tour-bounce the user.
        XCTAssertEqual(controller.currentIndex, advancedIndex)
    }

    @MainActor
    func test_start_emptyStepsArrayIsNoOp() {
        // Defensive guard: start() must not flip isPresenting=true on
        // an empty sequence. Otherwise the presenter would render an
        // overlay with a nil currentStep — invisible cover that can't
        // be dismissed and fires a phantom tutorial_started event.
        let controller = CoachMarkController(
            key: .scanCapture,
            steps: [],
            manager: manager,
        )
        controller.start()
        XCTAssertFalse(controller.isPresenting)
    }

    // MARK: - Advance + completion

    @MainActor
    func test_advance_walksAllStepsThenMarksCompleted() {
        let controller = CoachMarkController(
            key: .scanReview,
            steps: ScanReviewCoachMarks.steps,
            manager: manager,
        )
        controller.start()
        for _ in 0..<(ScanReviewCoachMarks.steps.count - 1) {
            controller.advance()
        }
        XCTAssertTrue(controller.isPresenting)
        XCTAssertTrue(controller.isFinalStep)
        XCTAssertFalse(manager.isCompleted(.scanReview))

        // Final advance triggers completion.
        controller.advance()
        XCTAssertFalse(controller.isPresenting)
        XCTAssertTrue(manager.isCompleted(.scanReview))
    }

    // MARK: - Skip

    @MainActor
    func test_skip_marksCompletedAndDismisses() {
        let controller = CoachMarkController(
            key: .cookModeTap,
            steps: CookModeTapCoachMarks.steps,
            manager: manager,
        )
        controller.start()
        controller.advance() // somewhere in the middle
        controller.skip()
        XCTAssertFalse(controller.isPresenting)
        XCTAssertTrue(manager.isCompleted(.cookModeTap))
    }

    // MARK: - Required-action gating

    @MainActor
    func test_completeAction_advancesWhenStepRequiresIt() {
        let controller = CoachMarkController(
            key: .scanCapture,
            steps: ScanCaptureCoachMarks.steps,
            manager: manager,
        )
        controller.start()
        // Step 0 is informational. Step 1 (`shutter`) requires
        // .shutterTap — advance past step 0 first.
        controller.advance()
        XCTAssertEqual(controller.currentStep?.requiredAction, .shutterTap)
        let preIndex = controller.currentIndex
        controller.completeAction(.shutterTap)
        // Final step → completion. `isPresenting` flips false.
        XCTAssertFalse(controller.isPresenting)
        XCTAssertTrue(manager.isCompleted(.scanCapture))
        XCTAssertEqual(preIndex, ScanCaptureCoachMarks.steps.count - 1)
    }

    @MainActor
    func test_completeAction_isNoOpWhenStepDoesNotRequireIt() {
        let controller = CoachMarkController(
            key: .scanReview,
            steps: ScanReviewCoachMarks.steps,
            manager: manager,
        )
        controller.start()
        // Step 0 is informational (no requiredAction). Calling
        // completeAction with anything must NOT advance.
        controller.completeAction(.shutterTap)
        controller.completeAction(.solveTap)
        XCTAssertEqual(controller.currentIndex, 0)
        XCTAssertTrue(controller.isPresenting)
    }

    @MainActor
    func test_completeAction_isNoOpForMismatchedAction() {
        let controller = CoachMarkController(
            key: .scanCapture,
            steps: ScanCaptureCoachMarks.steps,
            manager: manager,
        )
        controller.start()
        controller.advance() // now on the shutter step (requires .shutterTap)
        controller.completeAction(.solveTap) // wrong action
        XCTAssertEqual(controller.currentStep?.id, "shutter")
        XCTAssertTrue(controller.isPresenting)
    }

    // MARK: - Suspend (disappear-driven, non-terminal)

    @MainActor
    func test_suspend_dropsOverlayWithoutMarkingCompleted() {
        // Lifecycle invariant: disappear is non-terminal. The tour
        // should re-arm on re-appear, NOT be silently completed by a
        // tab switch / NavigationStack push / view-tree branch swap.
        let controller = CoachMarkController(
            key: .voiceMode,
            steps: VoiceModeCoachMarks.steps,
            manager: manager,
        )
        controller.start()
        controller.advance()
        controller.suspend()
        XCTAssertFalse(controller.isPresenting)
        XCTAssertFalse(manager.isCompleted(.voiceMode))
    }

    @MainActor
    func test_suspend_isNoOpIfNotPresenting() {
        let controller = CoachMarkController(
            key: .voiceMode,
            steps: VoiceModeCoachMarks.steps,
            manager: manager,
        )
        controller.suspend()
        XCTAssertFalse(controller.isPresenting)
        XCTAssertFalse(manager.isCompleted(.voiceMode))
    }

    @MainActor
    func test_suspendThenStart_resumesAtSameStep() {
        // Suspend leaves currentIndex untouched so a brief disappear-
        // reappear cycle resumes mid-tour rather than restarting from
        // step 0.
        let controller = CoachMarkController(
            key: .scanReview,
            steps: ScanReviewCoachMarks.steps,
            manager: manager,
        )
        controller.start()
        controller.advance()
        controller.advance()
        let preSuspendIndex = controller.currentIndex
        controller.suspend()
        controller.start()
        XCTAssertEqual(controller.currentIndex, preSuspendIndex)
    }

    // MARK: - Replay (post-skip restart)

    @MainActor
    func test_replayCycle_skipThenStartAgain_resetsToStepZero() {
        let controller = CoachMarkController(
            key: .scanReview,
            steps: ScanReviewCoachMarks.steps,
            manager: manager,
        )
        controller.start()
        controller.advance()
        controller.skip()
        XCTAssertFalse(controller.isPresenting)

        // Settings replay: manager.reset(...) clears the flag and
        // the host re-mounts; controller.start() must restart at
        // step 0, not resume mid-tour.
        manager.reset(.scanReview)
        controller.start()
        XCTAssertEqual(controller.currentIndex, 0)
        XCTAssertTrue(controller.isPresenting)
    }

    @MainActor
    func test_replayCycle_completeThenReset_allowsFreshStart() {
        // Full completion → reset → fresh start. Verifies that
        // didFireStarted is reset in finish() so the replay is a
        // genuine new presentation, not a controller stuck in a
        // post-completion state.
        let controller = CoachMarkController(
            key: .scanCapture,
            steps: ScanCaptureCoachMarks.steps,
            manager: manager,
        )
        controller.start()
        for _ in 0..<ScanCaptureCoachMarks.steps.count {
            controller.advance()
        }
        XCTAssertFalse(controller.isPresenting)
        XCTAssertTrue(manager.isCompleted(.scanCapture))

        manager.reset(.scanCapture)
        controller.start()
        XCTAssertTrue(controller.isPresenting)
        XCTAssertEqual(controller.currentIndex, 0)
    }

    // MARK: - Sequence sanity

    @MainActor
    func test_allSequencesHaveStepsAndStableIDs() {
        let sequences: [(TutorialKey, [CoachMarkStep])] = [
            (.scanCapture, ScanCaptureCoachMarks.steps),
            (.scanReview, ScanReviewCoachMarks.steps),
            (.dinnerOptions, DinnerOptionsCoachMarks.steps),
            (.dishPreview, DishPreviewCoachMarks.steps),
            (.cookModeTap, CookModeTapCoachMarks.steps),
            (.voiceMode, VoiceModeCoachMarks.steps),
            (.pantryManagement, PantryCoachMarks.steps),
            // SCA-14 — both pantry in-list variants share the same
            // TutorialKey but each is its own sequence; assert ID
            // uniqueness within each independently.
            (.pantryInListTour, PantryCoachMarks.inListTour),
            (.pantryInListTour, PantryCoachMarks.inListTourEmpty),
        ]
        for (key, steps) in sequences {
            XCTAssertFalse(steps.isEmpty, "\(key) has no steps")
            // IDs must be unique within a sequence — duplicates would
            // break SwiftUI transition diffing AND PostHog funnel
            // grouping. telemetryID is now an alias for id, so the
            // same uniqueness check covers both.
            let ids = steps.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "\(key) has duplicate step IDs")
        }
    }

    @MainActor
    func test_voiceModeSequence_includesCommandCatalog() {
        // The voice-mode "commands" step is the load-bearing one —
        // it's the only place users see the hands-free vocabulary.
        let commandsStep = VoiceModeCoachMarks.steps.first { $0.id == "commands" }
        XCTAssertNotNil(commandsStep)
        XCTAssertGreaterThanOrEqual(commandsStep?.voiceExamples.count ?? 0, 4)
        let phrases = (commandsStep?.voiceExamples ?? []).map(\.phrase)
        XCTAssertTrue(phrases.contains("next"))
        XCTAssertTrue(phrases.contains("repeat"))
        XCTAssertTrue(phrases.contains("help"))
        // Set-timer is the most spec-load-bearing voice command —
        // explicit assertion locks the exemplar phrasing.
        XCTAssertTrue(phrases.contains("set a 5-minute timer"))
    }

    @MainActor
    func test_allCoachMarkActionsHaveAtLeastOneStepConsumer() {
        // Every CoachMarkAction case MUST be the requiredAction of at
        // least one step. Catches dead enum cases and orphaned
        // completeAction call sites.
        let allSteps =
            ScanCaptureCoachMarks.steps +
            ScanReviewCoachMarks.steps +
            DinnerOptionsCoachMarks.steps +
            DishPreviewCoachMarks.steps +
            CookModeTapCoachMarks.steps +
            VoiceModeCoachMarks.steps
        let liveActions = Set(allSteps.compactMap(\.requiredAction))
        let allActions: Set<CoachMarkAction> = [
            .shutterTap, .solveTap, .cardTap, .nextStepTap, .startCookingTap,
        ]
        for action in allActions {
            XCTAssertTrue(
                liveActions.contains(action),
                "CoachMarkAction.\(action) has no step that requires it",
            )
        }
    }

    // MARK: - Anchor coordinate space

    @MainActor
    func test_coachMarkCoordinateSpace_isPerKey() {
        // Per-key coordinate space prevents collisions when nested
        // presenters mount simultaneously.
        let scanSpace = coachMarkCoordinateSpace(for: .scanCapture)
        let cookSpace = coachMarkCoordinateSpace(for: .cookModeTap)
        XCTAssertNotEqual(scanSpace, cookSpace)
        XCTAssertTrue(scanSpace.contains("scan_capture"))
        XCTAssertTrue(cookSpace.contains("cook_mode_tap"))
    }
}
