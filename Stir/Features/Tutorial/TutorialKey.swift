// TutorialKey
//
// One key per in-app tutorial. Each tutorial has its own UserDefaults
// flag — finishing one doesn't dismiss others.
//
// Naming: `tonightTour` is the four-step Tonight Home intro shipped in
// SCA-5. The rest are full-screen interactive walkthroughs (SCA-19)
// mounted on specific feature surfaces via `.tutorial(key:content:)`;
// they fire the first time the user lands on that surface, not at app
// launch.

import Foundation

enum TutorialKey: String, CaseIterable, Hashable, Sendable {
    /// Tonight Home — four-step intro (welcome / solve / saved /
    /// settings). Full-screen tutorial; runs once on first Tonight
    /// arrival after setup-onboarding completes.
    case tonightTour = "tonight_tour"

    /// Scan Mode — first time the user opens the camera capture
    /// screen. Three steps: aim → snap → wait, each with an
    /// interactive miniature of the camera workflow.
    case scanCapture = "scan_capture"

    /// Scan Review — first time the user lands on the parsed-
    /// ingredients screen. Walks the Confirmed / Needs Review buckets,
    /// the Add chip, and the Solve button.
    case scanReview = "scan_review"

    /// Dinner Options — three-up ranked dinners. Explains FitLabel
    /// semantics + tap-to-preview gesture.
    case dinnerOptions = "dinner_options"

    /// Dish Preview — pre-cook screen. Surfaces time/servings/pan
    /// meta, "why it fits" reasoning, and the Start Cooking CTA.
    case dishPreview = "dish_preview"

    /// Cook Mode (tap) — first cook session in tap mode. Step card,
    /// timer, substitution, advance gesture.
    case cookModeTap = "cook_mode_tap"

    /// Voice Mode — first voice session. Hands-free intro: listening
    /// pill, mic states, voice-command catalog ("next" / "repeat" /
    /// "set timer" / "help"), exit affordance.
    case voiceMode = "voice_mode"

    /// Pantry — first-run tutorial mounted on the Settings root
    /// (`SettingsRootView`). Two steps: why-the-pantry-matters
    /// (animated items filling a basket) → how-to-edit (drag-to-
    /// reveal demo). Tells the user what the Manage pantry row does
    /// and why kitchen-state matters for solves.
    case pantryManagement = "pantry_management"

    /// Pantry — populated in-list walkthrough fired the first time
    /// the user opens `PantryListView` with at least one item. Three
    /// steps: search-cycle demo → memory-state row reveals →
    /// pantry-impact stat blocks. View: `PantryInListPopulatedTutorial`.
    case pantryInListTour = "pantry_in_list_tour"

    /// Pantry — empty-state in-list walkthrough fired the first time
    /// the user opens `PantryListView` with NO items. Welcome →
    /// context primer → empty-state Add CTA (3-step
    /// `inListTourEmpty`). Distinct key from `pantryInListTour` so
    /// completing the empty tour (taps "Got it" → adds first item)
    /// does NOT burn the populated-tour bit; the populated variant
    /// fires fresh on the user's next visit. (SCA-17 C4 — earlier
    /// design used a single key + `.id()` remount, which silently
    /// suppressed the populated tour for the most natural new-user
    /// trajectory.)
    case pantryInListTourEmpty = "pantry_in_list_tour_empty"

    /// User-facing name surfaced in Settings replay copy.
    var displayName: String {
        switch self {
        case .tonightTour:    return "Tonight tour"
        case .scanCapture:    return "Scan tutorial"
        case .scanReview:     return "Scan review tutorial"
        case .dinnerOptions:  return "Dinner options tutorial"
        case .dishPreview:    return "Dish preview tutorial"
        case .cookModeTap:    return "Cook Mode tutorial"
        case .voiceMode:      return "Voice Mode tutorial"
        case .pantryManagement: return "Pantry tutorial"
        case .pantryInListTour: return "Pantry walkthrough"
        case .pantryInListTourEmpty: return "Pantry empty-state walkthrough"
        }
    }

    /// One-line replay subtitle. Lives with the key so per-key
    /// Settings rows stay in sync without copy-paste drift.
    var replaySubtitle: String {
        switch self {
        case .tonightTour:
            return "Replay the quick tour next time you open Tonight."
        case .scanCapture:
            return "Show how to scan your kitchen next time you open the camera."
        case .scanReview:
            return "Walk the scan-review screen again on the next solve."
        case .dinnerOptions:
            return "Re-explain how dinner cards are ranked."
        case .dishPreview:
            return "Re-explain the dish preview screen."
        case .cookModeTap:
            return "Replay the Cook Mode walkthrough next time you cook."
        case .voiceMode:
            return "Replay the Voice Mode walkthrough next time you go hands-free."
        case .pantryManagement:
            return "Re-explain the pantry the next time you open Settings."
        case .pantryInListTour:
            return "Walk through the pantry surface again next time you open it."
        case .pantryInListTourEmpty:
            return "Re-show the empty-pantry walkthrough next time the pantry is cleared."
        }
    }

    /// PostHog `tutorial_id` property — matches the rawValue.
    var telemetryID: String { rawValue }

    /// UserDefaults key written by `TutorialManager`. Namespaced.
    var defaultsKey: String { "stir.tutorial.completed.\(rawValue)" }
}
