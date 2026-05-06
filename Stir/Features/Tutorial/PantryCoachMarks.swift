// PantryCoachMarks
//
// Pantry feature tours. Two surfaces, two TutorialKeys (split by SCA-14
// after the original "one key, two phases" plan turned out to be a
// worse fit for replay UX):
//
//   `pantryManagement` — Settings entry point (this file: `steps`)
//     One coach mark on the "Manage pantry" row. Mounted on
//     `SettingsRootView`. Tells a returning user what the row does and
//     why kitchen-state matters for solves.
//
//   `pantryInListTour` — In-screen walkthrough (this file: `inListTour`
//     and `inListTourEmpty`). Mounted on `PantryListView`. The presenter
//     picks the variant at attach time based on `vm.items.isEmpty`.
//
// Two keys means Settings replay re-fires whichever tour matches the
// surface the user is on, and an empty-pantry user who later populates
// it doesn't get the welcome tour again unless they explicitly replay.

import Foundation

enum PantryCoachMarks {
    /// `pantryManagement` sequence — single entry-point coach mark on
    /// the Settings → "Manage pantry" row.
    static let steps: [CoachMarkStep] = [
        CoachMarkStep(
            id: "entry",
            anchor: .settingsManagePantryRow,
            placement: .below,
            title: "Your kitchen, remembered",
            message: "Stir keeps a pantry of what you've scanned and added so it can suggest dinners you can actually make. Tap Manage pantry to view, edit, or remove items.",
        ),
    ]

    // MARK: - SCA-14 — In-list walkthrough
    //
    // Two variants under `TutorialKey.pantryInListTour`:
    //
    //   `inListTour` (5 steps) — populated pantry. welcome → header
    //     strip → toolbar `+` → row tap/swipe → source-glyph legend.
    //
    //   `inListTourEmpty` (3 steps) — empty pantry. welcome → header
    //     context (so the user knows what the cap means before they
    //     fill it) → empty-state Add CTA. Skips the row-anchored
    //     steps because there's no row to spotlight.
    //
    // The presenter modifier chooses between them at attach time
    // based on `vm.items.isEmpty`. Same TutorialKey backs both —
    // resolution writes the same UserDefaults flag, so a user who
    // saw the empty variant doesn't get the full variant later
    // (and vice-versa). If you want both, replay from Settings.

    /// Step IDs are variant-prefixed (`populated_*` / `empty_*`) so
    /// PostHog funnel queries that group on `tutorial_id + from_step`
    /// can split the two cohorts even though both variants share the
    /// `pantry_in_list_tour` tutorial_id. Without the prefix, both
    /// variants emitting `from_step="welcome"` would conflate.
    static let inListTour: [CoachMarkStep] = [
        CoachMarkStep(
            id: "populated_welcome",
            placement: .center,
            title: "Welcome to your pantry",
            message: "Stir uses what's in here to suggest dinners you can actually make. The list updates every time you scan or add an item.",
        ),
        CoachMarkStep(
            id: "populated_header",
            anchor: .pantryHeaderStrip,
            placement: .below,
            title: "How much room you've got",
            message: "Standing items count toward your cap. Today items don't — they're for one-night ingredients you don't want to keep around.",
        ),
        CoachMarkStep(
            id: "populated_add",
            anchor: .pantryAddButton,
            placement: .below,
            title: "Tap + to add by hand",
            message: "Most items get added by scan. Use + when Stir misses something — or for a one-off you bought today.",
        ),
        CoachMarkStep(
            id: "populated_edit_remove",
            anchor: .pantryFirstRow,
            placement: .below,
            title: "Tap to edit, swipe to remove",
            message: "Tap any row to change its name, amount, or memory state. Swipe left to remove it.",
        ),
        CoachMarkStep(
            id: "populated_source_glyph",
            anchor: .pantryListSourceGlyph,
            placement: .below,
            title: "Where each item came from",
            message: "Camera = scanned. Pencil = typed. Star = staple. Stack = imported from a recipe.",
        ),
    ]

    static let inListTourEmpty: [CoachMarkStep] = [
        CoachMarkStep(
            id: "empty_welcome",
            placement: .center,
            title: "Welcome to your pantry",
            message: "Stir uses what's in here to suggest dinners you can actually make. Right now it's empty — let's fix that.",
        ),
        CoachMarkStep(
            id: "empty_header_context",
            placement: .center,
            title: "How the pantry fills up",
            message: "Scanning your fridge or pantry is the fastest way to populate the list. You can also add items by hand below.",
        ),
        CoachMarkStep(
            id: "empty_add",
            anchor: .pantryListEmptyAdd,
            // `.auto` lets the presenter heuristic pick above/below
            // based on where the empty-state Add button lands. On
            // smaller screens (iPhone SE 320pt content height) `.above`
            // would risk overlap with the body copy block above the
            // button.
            placement: .auto,
            title: "Add your first item",
            message: "Tap Add an item to type one in, then come back here whenever you want to manage what Stir knows about your kitchen.",
        ),
    ]
}
