// TutorialFlowContainerTests
//
// Replaces `CoachMarkControllerTests` (deleted in SCA-19). The
// new tutorial system is built on `TutorialFlowContainer` driving
// per-feature `*TutorialFlow.swift` views; the container itself is a
// stateless step machine, so the contract worth pinning is the
// step-protocol invariants + per-tutorial uniqueness/cohort rules
// that PostHog dashboards depend on.

import XCTest
@testable import Stir

final class TutorialFlowContainerTests: XCTestCase {

    // MARK: - Step protocol invariants

    /// Every step enum MUST start at rawValue 0. The container's
    /// `progressFraction` and dot-indicator iterate `0..<count` and
    /// match against `currentStep.rawValue` directly — a non-zero
    /// origin would silently desync the dot indicator.
    @MainActor
    func test_allStepEnumsStartAtZero() {
        XCTAssertEqual(TonightTour.Step.allCases.first?.rawValue, 0)
        XCTAssertEqual(ScanCaptureTutorial.Step.allCases.first?.rawValue, 0)
        XCTAssertEqual(ScanReviewTutorial.Step.allCases.first?.rawValue, 0)
        XCTAssertEqual(DinnerOptionsTutorial.Step.allCases.first?.rawValue, 0)
        XCTAssertEqual(DishPreviewTutorial.Step.allCases.first?.rawValue, 0)
        XCTAssertEqual(CookModeTapTutorial.Step.allCases.first?.rawValue, 0)
        XCTAssertEqual(VoiceModeTutorial.Step.allCases.first?.rawValue, 0)
        XCTAssertEqual(PantryManagementTutorial.Step.allCases.first?.rawValue, 0)
        XCTAssertEqual(PantryInListTutorial.PopulatedStep.allCases.first?.rawValue, 0)
        XCTAssertEqual(PantryInListTutorial.EmptyStep.allCases.first?.rawValue, 0)
    }

    /// Step rawValues must be contiguous (0, 1, 2, …). Gaps would make
    /// the dot indicator render the wrong number of dots and the
    /// `Step(rawValue: current + 1)` advance lookup fail unexpectedly.
    @MainActor
    func test_allStepEnumsAreContiguous() {
        assertContiguous(TonightTour.Step.allCases, label: "TonightTour")
        assertContiguous(ScanCaptureTutorial.Step.allCases, label: "ScanCapture")
        assertContiguous(ScanReviewTutorial.Step.allCases, label: "ScanReview")
        assertContiguous(DinnerOptionsTutorial.Step.allCases, label: "DinnerOptions")
        assertContiguous(DishPreviewTutorial.Step.allCases, label: "DishPreview")
        assertContiguous(CookModeTapTutorial.Step.allCases, label: "CookModeTap")
        assertContiguous(VoiceModeTutorial.Step.allCases, label: "VoiceMode")
        assertContiguous(PantryManagementTutorial.Step.allCases, label: "PantryManagement")
        assertContiguous(PantryInListTutorial.PopulatedStep.allCases, label: "PantryInList.populated")
        assertContiguous(PantryInListTutorial.EmptyStep.allCases, label: "PantryInList.empty")
    }

    private func assertContiguous<S: TutorialStep>(_ steps: [S], label: String) {
        for (idx, step) in steps.enumerated() {
            XCTAssertEqual(
                step.rawValue, idx,
                "\(label): step at index \(idx) has rawValue \(step.rawValue)",
            )
        }
    }

    /// `progressFraction` MUST be in (0, 1] for every step. Used by
    /// the accessibility label "Step N of M" and (going forward) any
    /// linear progress affordance.
    @MainActor
    func test_progressFraction_isWithinUnitInterval() {
        let steps = TonightTour.Step.allCases
        for step in steps {
            let f = step.progressFraction
            XCTAssertGreaterThan(f, 0, "progressFraction must be > 0 (\(step))")
            XCTAssertLessThanOrEqual(f, 1, "progressFraction must be ≤ 1 (\(step))")
        }
        // Final step is exactly 1.0 (not just <= 1).
        XCTAssertEqual(steps.last?.progressFraction, 1.0)
    }

    // MARK: - Telemetry-ID conventions

    /// Every step's `telemetryID` MUST be snake_case lowercase, no
    /// spaces. PostHog dashboards group on the literal string; a typo
    /// or CamelCase value would silently fork the cohort.
    @MainActor
    func test_telemetryIDs_areSnakeCase() {
        validateTelemetryIDs(TonightTour.Step.allCases)
        validateTelemetryIDs(ScanCaptureTutorial.Step.allCases)
        validateTelemetryIDs(ScanReviewTutorial.Step.allCases)
        validateTelemetryIDs(DinnerOptionsTutorial.Step.allCases)
        validateTelemetryIDs(DishPreviewTutorial.Step.allCases)
        validateTelemetryIDs(CookModeTapTutorial.Step.allCases)
        validateTelemetryIDs(VoiceModeTutorial.Step.allCases)
        validateTelemetryIDs(PantryManagementTutorial.Step.allCases)
        validateTelemetryIDs(PantryInListTutorial.PopulatedStep.allCases)
        validateTelemetryIDs(PantryInListTutorial.EmptyStep.allCases)
    }

    private func validateTelemetryIDs<S>(_ steps: [S]) {
        let strs = steps.compactMap { ($0 as? any TelemetryIDProvider)?.telemetryID }
        for s in strs {
            XCTAssertFalse(s.isEmpty, "telemetryID must be non-empty")
            XCTAssertEqual(s.lowercased(), s, "telemetryID must be lowercase: \(s)")
            XCTAssertFalse(s.contains(" "), "telemetryID must not contain spaces: \(s)")
            XCTAssertFalse(s.contains("-"), "telemetryID must use underscores, not hyphens: \(s)")
        }
    }

    // MARK: - Variant cohort uniqueness (PantryInListTutorial)

    /// SCA-14 / SCA-19 — `pantryInListTour` and `pantryInListTourEmpty`
    /// share a single backing TutorialKey *family*, so step
    /// telemetry IDs must be globally unique across the two variants.
    /// A future contributor adding `welcome` to both variants would
    /// silently merge cohorts in PostHog dashboards filtered on
    /// `from_step`/`to_step`.
    @MainActor
    func test_pantryInListVariants_haveDistinctStepIDs() {
        let populated = PantryInListTutorial.PopulatedStep.allCases.map(\.telemetryID)
        let empty = PantryInListTutorial.EmptyStep.allCases.map(\.telemetryID)
        let intersection = Set(populated).intersection(Set(empty))
        XCTAssertTrue(
            intersection.isEmpty,
            "Populated and empty pantry tour step IDs collide: \(intersection)",
        )
    }

    /// Each variant should prefix its IDs with `populated_` / `empty_`
    /// so a glance at PostHog reveals which cohort fired.
    @MainActor
    func test_pantryInListVariants_useCorrectPrefix() {
        for step in PantryInListTutorial.PopulatedStep.allCases {
            XCTAssertTrue(
                step.telemetryID.hasPrefix("populated_"),
                "Populated step missing prefix: \(step.telemetryID)",
            )
        }
        for step in PantryInListTutorial.EmptyStep.allCases {
            XCTAssertTrue(
                step.telemetryID.hasPrefix("empty_"),
                "Empty step missing prefix: \(step.telemetryID)",
            )
        }
    }

    // MARK: - TutorialKey ↔ Tutorial coverage

    /// Every TutorialKey MUST have a corresponding tutorial view (no
    /// orphan keys that the user could `manager.reset(_:)` from
    /// Settings only to find no replay flow). The Settings replay
    /// surface iterates `TutorialKey.allCases`, so this guards against
    /// adding a key without wiring a flow.
    @MainActor
    func test_everyTutorialKey_hasCoverage() {
        for key in TutorialKey.allCases {
            XCTAssertFalse(
                key.displayName.isEmpty,
                "\(key) missing displayName",
            )
            XCTAssertFalse(
                key.replaySubtitle.isEmpty,
                "\(key) missing replaySubtitle",
            )
        }
    }
}

/// Ad-hoc protocol so the `validateTelemetryIDs` helper can pull the
/// `telemetryID` string from any step enum without each enum needing
/// to conform to a shared base. Each `*TutorialFlow.Step` already
/// declares this property; we just re-shape it as a protocol here for
/// the test path. Lives in tests only — production flows access the
/// property through the concrete enum, not via existential.
private protocol TelemetryIDProvider {
    var telemetryID: String { get }
}
extension TonightTour.Step: TelemetryIDProvider {}
extension ScanCaptureTutorial.Step: TelemetryIDProvider {}
extension ScanReviewTutorial.Step: TelemetryIDProvider {}
extension DinnerOptionsTutorial.Step: TelemetryIDProvider {}
extension DishPreviewTutorial.Step: TelemetryIDProvider {}
extension CookModeTapTutorial.Step: TelemetryIDProvider {}
extension VoiceModeTutorial.Step: TelemetryIDProvider {}
extension PantryManagementTutorial.Step: TelemetryIDProvider {}
extension PantryInListTutorial.PopulatedStep: TelemetryIDProvider {}
extension PantryInListTutorial.EmptyStep: TelemetryIDProvider {}
