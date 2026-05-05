// PantryCoachMarks
//
// Pantry feature tour. Two phases stitched together via a single
// `pantryManagement` TutorialKey:
//
//   Phase 1 — Settings entry point
//     One coach mark on the "Manage pantry" row. Fires the first time
//     a user with a populated scan history reaches Settings after the
//     pantry surface ships. Tells them what the row does AND why
//     they'd care (kitchen state powers dinner solves and grocery
//     diffs). Step `entry` below.
//
//   Phase 2 — Inside PantryListView
//     Walks the cap headroom strip → Add button → Today vs Standing
//     picker → row affordances. Anchored at elements that don't yet
//     exist in the codebase; sequence compiles against pre-defined
//     `CoachMarkAnchorID` cases so the moment `PantryListView` ships,
//     wiring is `.coachMarks(key: .pantryManagement, steps:
//     PantryCoachMarks.steps)` on the screen body and nothing else.
//
// Why both phases share one TutorialKey: a returning user replays the
// whole pantry story end-to-end via Settings → Replay tutorials. If
// the entry was its own key, Settings replay would only re-fire the
// row tip and leave the in-screen walkthrough silent until the user
// dirtied state via reset-and-touch.

import Foundation

enum PantryCoachMarks {
    static let steps: [CoachMarkStep] = [
        // Phase 1 — Settings row entry point.
        CoachMarkStep(
            id: "entry",
            anchor: .settingsManagePantryRow,
            placement: .below,
            title: "Your kitchen, remembered",
            message: "Stir keeps a pantry of what you've scanned and added so it can suggest dinners you can actually make. Tap Manage pantry to view, edit, or remove items.",
        ),

        // Phase 2 — In-screen walkthrough. Each step anchors on an
        // element that lives inside PantryListView. Until the view
        // ships these are pre-registered no-ops; the moment it lands
        // they wire up automatically.

        CoachMarkStep(
            id: "header",
            anchor: .pantryHeaderStrip,
            placement: .below,
            title: "How much room you've got",
            message: "Standing items count toward your tier's pantry cap. Today items don't — they're for one-night ingredients you don't want to keep around.",
        ),
        CoachMarkStep(
            id: "add",
            anchor: .pantryAddButton,
            placement: .above,
            title: "Add something Stir didn't see",
            message: "Tap + to add an item by name. Most users let scans do the work; manual add is the fallback for the staples Stir misses.",
        ),
        CoachMarkStep(
            id: "memory_state",
            anchor: .pantryMemoryStatePicker,
            placement: .above,
            title: "Today vs Standing",
            message: "Standing means \"I always keep this around\" — counts toward your cap. Today means \"only for tonight\" — bypasses the cap and falls off after one solve.",
        ),
        CoachMarkStep(
            id: "edit_remove",
            anchor: .pantryFirstRow,
            placement: .below,
            title: "Tap to edit, swipe to remove",
            message: "Tap any row to change its name, amount, or memory state. Swipe left on a row to remove it — or use Remove from pantry inside the edit sheet.",
        ),
    ]

    /// Convenience accessor for the entry-point step alone. Settings
    /// hosts this single step until `PantryListView` ships, at which
    /// point the full sequence (`steps` above) replaces it on the
    /// pantry screen and Settings drops the standalone wiring.
    static let entryOnly: [CoachMarkStep] = Array(steps.prefix(1))
}
