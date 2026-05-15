// RecipePlanDurationTests
//
// SCA-438 (W1) — coverage for the SCA-422 fix in
// `RecipePlan.remainingDurationMinutes(fromStepIndex:)`. The function
// drives the "~T min left" label on every Cook Mode session for every
// user, and before SCA-422 it pinned to the only-timer step's value
// for the whole pre-timer prefix of the recipe — a real bug only
// surfaced from a beta-tester screenshot. The /review-2 pass on
// SCA-422 + SCA-433 (both DB1 and CA1) flagged the absence of tests
// here as the highest-confidence finding.
//
// Coverage matrix:
//   * All-timer-bearing recipe (no overhead): timer-sum semantics.
//   * Zero-timer + nonzero estimatedMinutes (legacy/intuitive
//     recipe): pure-overhead distribution decreases evenly.
//   * Mixed timer + nonzero overhead (the typical SCA-422 case):
//     monotonic non-increasing across all step indices.
//   * estimatedMinutes < sum(timerSeconds): overhead clamps to 0,
//     result reduces to timer-only sum (legacy fallback contract).
//   * Empty plan: returns 0.
//   * Out-of-range index (negative, == count, > count): clamps to
//     the valid window; never traps, never returns negative.
//   * Single-step recipe: clamp boundary on stepArray.count == 1.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class RecipePlanDurationTests: XCTestCase {
    private var pc: PersistenceController!
    private var household: HouseholdProfile!

    override func setUp() async throws {
        try await super.setUp()
        pc = PersistenceController(inMemory: true)
        let ctx = pc.viewContext
        household = HouseholdProfile(context: ctx)
        household.id = UUID()
        household.createdAt = Date()
        try ctx.save()
    }

    override func tearDown() async throws {
        household = nil
        pc = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Build a RecipePlan with explicit per-step `timerSeconds` and a
    /// total `estimatedMinutes`. Steps are appended in array order
    /// with matching `sortOrder` / `stepNumber` so `stepArray` returns
    /// them in the same order.
    @discardableResult
    private func makePlan(
        estimatedMinutes: Int,
        timerSecondsPerStep: [Int],
    ) throws -> RecipePlan {
        let ctx = pc.viewContext
        let plan = RecipePlan(context: ctx)
        plan.id = UUID()
        plan.household = household
        plan.title = "Test"
        plan.servings = 2
        plan.estimatedMinutes = Int16(clamping: estimatedMinutes)
        plan.typedOrigin = .ai
        plan.createdAt = Date()
        plan.updatedAt = Date()
        for (idx, sec) in timerSecondsPerStep.enumerated() {
            let step = RecipeStep(context: ctx)
            step.id = UUID()
            step.recipePlan = plan
            step.stepNumber = Int16(idx)
            step.sortOrder = Int16(idx)
            step.instructionText = "Step \(idx + 1)"
            step.timerSeconds = Int32(sec)
        }
        try ctx.save()
        return plan
    }

    // MARK: - Branch coverage

    /// All-timer-bearing recipe (rare but possible). With
    /// `estimatedMinutes` equal to the sum of timer minutes, the
    /// overhead branch contributes zero and the label reduces to a
    /// running suffix-sum of timer minutes.
    func test_allTimerSteps_returnsRunningTimerSum() throws {
        // 4 steps of 3 minutes each → 12 minutes total timer.
        let plan = try makePlan(
            estimatedMinutes: 12,
            timerSecondsPerStep: [180, 180, 180, 180],
        )
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 0), 12)
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 1), 9)
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 2), 6)
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 3), 3)
    }

    /// Zero-timer + nonzero estimatedMinutes — the SCA-422 path the
    /// fix was written for. Overhead distributes evenly; the label
    /// must decrease step-over-step.
    func test_zeroTimerSteps_distributeOverheadEvenly() throws {
        // 5 steps, 25 min total, no per-step timers. Each step's
        // share is 25*60 / 5 = 300 sec, so:
        //   step 0: 5 * 300 = 1500 sec → 25 min
        //   step 1: 4 * 300 = 1200 sec → 20 min
        //   step 2: 3 * 300 =  900 sec → 15 min
        //   step 3: 2 * 300 =  600 sec → 10 min
        //   step 4: 1 * 300 =  300 sec →  5 min
        let plan = try makePlan(
            estimatedMinutes: 25,
            timerSecondsPerStep: [0, 0, 0, 0, 0],
        )
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 0), 25)
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 1), 20)
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 2), 15)
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 3), 10)
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 4), 5)
    }

    /// The exact SCA-422 repro: one timer-bearing step embedded in a
    /// 5-step recipe with overhead. Pre-fix this stayed pinned at the
    /// timer's value for the whole pre-timer prefix; post-fix it
    /// decreases monotonically.
    func test_singleTimerStepWithOverhead_monotonicDecrease() throws {
        // 5 steps, 25 min total, only step 2 (0-indexed) has a 3-min
        // timer. timerSum = 180s. overhead = 25*60 - 180 = 1320s.
        // perStepOverhead = 1320 / 5 = 264s. Per-step calc:
        //   index 0: timer = 180, overhead = 5*264=1320 → 1500s → 25 min
        //   index 1: timer = 180, overhead = 4*264=1056 → 1236s → ceil(1236/60)=21
        //   index 2: timer = 180, overhead = 3*264=792  → 972s  → ceil(972/60)=17
        //   index 3: timer = 0,   overhead = 2*264=528  → 528s  → ceil(528/60)=9
        //   index 4: timer = 0,   overhead = 1*264=264  → 264s  → ceil(264/60)=5
        let plan = try makePlan(
            estimatedMinutes: 25,
            timerSecondsPerStep: [0, 0, 180, 0, 0],
        )
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 0), 25)
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 1), 21)
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 2), 17)
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 3), 9)
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 4), 5)
        // Monotonic non-increasing across the full step range — the
        // load-bearing invariant the SCA-422 fix introduced.
        for i in 0 ..< (plan.stepArray.count - 1) {
            let m1 = plan.remainingDurationMinutes(fromStepIndex: i)
            let m2 = plan.remainingDurationMinutes(fromStepIndex: i + 1)
            XCTAssertGreaterThanOrEqual(
                m1, m2,
                "monotonic non-increasing violated at index \(i): m[\(i)]=\(m1) < m[\(i+1)]=\(m2)",
            )
        }
    }

    /// `estimatedMinutes` smaller than the timer sum — degenerate but
    /// possible if the AI under-budgets total time. Overhead must
    /// clamp to 0; result reduces to timer-only sum.
    func test_estimatedLessThanTimerSum_clampsOverheadToZero() throws {
        // Timer sum = 600s = 10 min, but estimatedMinutes = 5.
        // Overhead = max(0, 5*60 - 600) = 0. Result = timer suffix sum.
        let plan = try makePlan(
            estimatedMinutes: 5,
            timerSecondsPerStep: [120, 120, 120, 120, 120],
        )
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 0), 10)
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 4), 2)
    }

    /// `estimatedMinutes == 0` (legacy recipe with no AI-provided
    /// total). Falls back to timer-only sum so legacy recipes still
    /// render rather than going to 0 min left when they have timers.
    func test_zeroEstimatedMinutesWithTimers_fallsBackToTimerSum() throws {
        let plan = try makePlan(
            estimatedMinutes: 0,
            timerSecondsPerStep: [0, 0, 180, 0, 0],
        )
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 0), 3)
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 2), 3)
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 3), 0)
    }

    /// Pure-zero plan: no timers and no estimate. Returns 0 so the
    /// recipe strip's `if remainingMin > 0` guard hides the label
    /// rather than rendering "~0 min left".
    func test_noTimersNoEstimate_returnsZero() throws {
        let plan = try makePlan(
            estimatedMinutes: 0,
            timerSecondsPerStep: [0, 0, 0],
        )
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 0), 0)
    }

    /// Plan with zero steps. Hits the early-out before any arithmetic.
    func test_emptyStepArray_returnsZero() throws {
        let plan = try makePlan(estimatedMinutes: 30, timerSecondsPerStep: [])
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 0), 0)
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 5), 0)
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: -1), 0)
    }

    /// Single-step plan — the smallest valid count. Confirms the
    /// clamp on `steps.count == 1` doesn't underflow `stepsRemaining`.
    func test_singleStepPlan_handlesClampCleanly() throws {
        let plan = try makePlan(estimatedMinutes: 10, timerSecondsPerStep: [120])
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 0), 10)
        // index == count is the post-last position. clamps to count,
        // stepsRemaining == 0, returns 0.
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 1), 0)
    }

    /// Out-of-range indices clamp into the valid window rather than
    /// trapping. Negative → 0; past the end → 0 (no steps remaining).
    func test_outOfRangeIndex_clampsCleanly() throws {
        let plan = try makePlan(
            estimatedMinutes: 25,
            timerSecondsPerStep: [0, 0, 180, 0, 0],
        )
        // Negative index clamps to 0 — same as fromStepIndex: 0.
        XCTAssertEqual(
            plan.remainingDurationMinutes(fromStepIndex: -1),
            plan.remainingDurationMinutes(fromStepIndex: 0),
        )
        XCTAssertEqual(
            plan.remainingDurationMinutes(fromStepIndex: -100),
            plan.remainingDurationMinutes(fromStepIndex: 0),
        )
        // Index >= count clamps to count → stepsRemaining == 0 → 0.
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 5), 0)
        XCTAssertEqual(plan.remainingDurationMinutes(fromStepIndex: 100), 0)
    }
}
