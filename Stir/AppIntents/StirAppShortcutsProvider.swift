// StirAppShortcutsProvider
//
// Exposes Stir's AppIntents to the system Shortcuts app + Siri
// suggestions. iOS 16+ `AppShortcutsProvider` replaces the old
// SiriKit Intents Extension — the whole thing lives in the main
// app target.
//
// Phrase design rules (per Apple's docs):
//   - Include the app name or stable equivalent in every phrase.
//   - Use short, natural prompts — Siri matches phonetically.
//   - Prefer declarative ("Tonight's Stir dinner") over imperative
//     ("tell me what Stir says") for better recognition.
//
// Donation (intent.donate()) happens elsewhere — SolveViewModel
// donates StartNewDinnerSolveIntent after every successful solve
// so Siri starts suggesting it contextually after the user
// establishes the habit.

import AppIntents

struct StirAppShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartNewDinnerSolveIntent(),
            phrases: [
                "Start a dinner in \(.applicationName)",
                "New dinner in \(.applicationName)",
                "What should I cook with \(.applicationName)",
            ],
            shortTitle: "Start dinner",
            systemImageName: "fork.knife",
        )
        AppShortcut(
            intent: ShowTonightsIdeaIntent(),
            phrases: [
                "Tonight's dinner in \(.applicationName)",
                "What's for dinner in \(.applicationName)",
                "Tell me tonight's \(.applicationName) idea",
            ],
            shortTitle: "Tonight's idea",
            systemImageName: "sparkles",
        )
        AppShortcut(
            intent: AddToGroceryIntent(),
            phrases: [
                "Add tonight to grocery in \(.applicationName)",
                "Build \(.applicationName) grocery list",
            ],
            shortTitle: "Add to grocery",
            systemImageName: "cart",
        )
    }

    /// Color used for the Shortcuts tile background. Matches the
    /// ember accent so shortcuts look on-brand in the Shortcuts app.
    static var shortcutTileColor: ShortcutTileColor { .orange }
}
