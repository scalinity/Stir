// StartNewDinnerSolveIntent
//
// "Hey Siri, what should I cook?" / Shortcuts tile that launches
// Stir into the Scan flow. Opens the app (not background-run —
// scanning needs the camera) and relies on the URL-based deep link
// `stir://scan/start` to route via RootView.onOpenURL →
// StirDeepLinkHandler.
//
// Donated after every successful solve (see SolveViewModel
// persistCompletedSolve) so Siri starts suggesting the shortcut
// contextually once the user has established the habit.
//
// Gate: Premium+ only (spec §9). `shortcut_run` telemetry fires on
// every invocation.

import AppIntents
import Foundation

struct StartNewDinnerSolveIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a new dinner"
    static let description = IntentDescription(
        "Opens Stir and starts a fresh scan → dinner solve.",
        categoryName: "Planning",
    )

    /// Must open the app — Scan needs the camera which can't run in
    /// the intent's detached process.
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        StirAppIntentsGate.recordInvocation("StartNewDinnerSolveIntent")
        guard StirAppIntentsGate.isPermitted() else {
            return .result(dialog: StirAppIntentsGate.upgradeDialog)
        }
        // openAppWhenRun handles foregrounding. Specific-screen routing
        // (stir://scan/start) arrives with the step-8 router refactor
        // that wires intent destinations through RootCoordinator.
        return .result(dialog: IntentDialog("Opening Stir to start your scan."))
    }
}
