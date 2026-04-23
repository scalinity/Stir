// ShowTonightsIdeaIntent
//
// "Hey Siri, what's for dinner?" / Shortcuts card that surfaces the
// top dish from the latest solve. Reads the App-Group-shared
// TonightSnapshot (same cache StirWidgets reads) so the intent can
// resolve without waking the full app or Core Data stack.
//
// Returns:
//   - Dialog  : Siri voice-over of the top dish title
//   - String  : dish title as a Shortcuts-chainable value (the user
//               can pipe it into another action — e.g. "Add to notes")
//
// Gate: Premium+ only. Gated invocations fire `shortcut_run` with
// the intent name, then return the upgrade dialog.

import AppIntents
import Foundation

struct ShowTonightsIdeaIntent: AppIntent {
    static let title: LocalizedStringResource = "Show tonight's dinner idea"
    static let description = IntentDescription(
        "Surfaces the top dish from your most recent solve.",
        categoryName: "Planning",
    )

    /// Background-runnable — just reads SharedStorage + returns.
    /// No app open needed unless the user taps the Shortcuts result.
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        StirAppIntentsGate.recordInvocation("ShowTonightsIdeaIntent")
        guard StirAppIntentsGate.isPermitted() else {
            return .result(
                value: "",
                dialog: StirAppIntentsGate.upgradeDialog,
            )
        }
        guard let snapshot = SharedStorage().readTonight(),
              let top = snapshot.topDishes.first else {
            return .result(
                value: "",
                dialog: IntentDialog("No solve yet. Open Stir and scan your kitchen."),
            )
        }
        let title = top.title
        let dialog = IntentDialog("\(title). About \(top.totalTimeMin) minutes.")
        return .result(value: title, dialog: dialog)
    }
}
