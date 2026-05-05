// TutorialKey
//
// One key per in-app tutorial. Each tutorial has its own UserDefaults
// flag — finishing one doesn't dismiss others.
//
// Naming: `tonightTour` is the four-step Tonight Home intro shipped in
// SCA-5. The rest are contextual coach-mark sequences attached to
// specific feature surfaces; they fire the first time the user lands
// on that surface, not at app launch.

import Foundation

enum TutorialKey: String, CaseIterable, Hashable, Sendable {
    /// Tonight Home — four-step intro (welcome / solve / saved /
    /// settings). Full-screen tutorial; runs once on first Tonight
    /// arrival after setup-onboarding completes.
    case tonightTour = "tonight_tour"

    /// Scan Mode — first time the user opens the camera capture
    /// screen. Two coach-mark steps: framing tip + shutter prompt.
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

    /// Pantry — first time the user reaches Settings post-pantry-
    /// launch. Entry-point coach mark on the "Manage pantry" row
    /// explains what the pantry is for; the in-screen walkthrough
    /// (Today vs Standing, cap headroom, swipe-to-remove) presents
    /// inside `PantryListView` once it ships.
    case pantryManagement = "pantry_management"

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
        }
    }

    /// PostHog `tutorial_id` property — matches the rawValue.
    var telemetryID: String { rawValue }

    /// UserDefaults key written by `TutorialManager`. Namespaced.
    var defaultsKey: String { "stir.tutorial.completed.\(rawValue)" }
}
