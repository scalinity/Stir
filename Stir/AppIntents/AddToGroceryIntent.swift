// AddToGroceryIntent
//
// Shortcuts entry: "Add tonight's ingredients to grocery." Takes the
// latest TonightSnapshot's top dish id (or an explicit recipe id if
// the user chained from another action) and deep-links Stir into the
// Grocery flow for that recipe.
//
// v1 simplification: no parameter picker yet. The intent always
// targets the snapshot's top dish — matches the "Hey Siri, add
// tonight's grocery" phrasing. A parameter-taking variant can land
// in step 8 when Saved's per-recipe shortcut donation is wired.
//
// Gate: Premium+ only. Intent opens the app to route the flow; the
// actual grocery generate call runs inside Stir's main process.

import AppIntents
import Foundation

struct AddToGroceryIntent: AppIntent {
    static let title: LocalizedStringResource = "Add tonight's recipe to grocery"
    static let description = IntentDescription(
        "Opens Stir and builds a grocery list for tonight's top dish.",
        categoryName: "Grocery",
    )

    /// Opens the app. GroceryListView needs the Core Data +
    /// AIDispatch context that only lives in the main process.
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        StirAppIntentsGate.recordInvocation("AddToGroceryIntent")
        guard StirAppIntentsGate.isPermitted() else {
            return .result(dialog: StirAppIntentsGate.upgradeDialog)
        }
        guard let snapshot = SharedStorage().readTonight(),
              let top = snapshot.topDishes.first else {
            return .result(dialog: IntentDialog(
                "No recent solve to build a list from. Open Stir first.",
            ))
        }
        // openAppWhenRun foregrounds Stir; step-8 routing wires the
        // specific grocery destination (stir://solve/<id>/dish/<id>).
        return .result(dialog: IntentDialog(
            "Opening Stir — I'll diff \(top.title) against your pantry.",
        ))
    }
}
