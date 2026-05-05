// VoiceModeCoachMarks
//
// Coach-mark sequence for the first Voice Mode session. The unique
// thing here is the voice-command catalog — users can't discover
// hands-free commands by looking, so the third step lists them
// explicitly with quoted phrasing.
//
// Voice tutorials are intentionally informational only. The mic stays
// open underneath the overlay; the user reads the commands, dismisses
// the tutorial, and the next thing the model says picks up live voice
// mode. We do NOT attempt to listen for tutorial-time speech — live
// transcription errors during a tutorial are a recovery nightmare.

import Foundation

enum VoiceModeCoachMarks {
    static let steps: [CoachMarkStep] = [
        CoachMarkStep(
            id: "intro",
            anchor: .voiceListeningPill,
            placement: .above,
            title: "Hands-free Cook Mode",
            message: "You're in Voice Mode. Stir reads each step out loud and listens for what you say next — no Next button required.",
        ),
        CoachMarkStep(
            id: "mic_states",
            anchor: .voiceListeningPill,
            placement: .above,
            title: "Watch the mic glow",
            message: "Ember pulse means Stir is listening. Voice-tinted pulse means Stir is talking back. The waveform shows when your voice lands.",
        ),
        CoachMarkStep(
            id: "commands",
            placement: .center,
            title: "Try saying any of these",
            message: "Speak naturally — no wake word. Anytime Stir is listening you can say:",
            voiceExamples: [
                .init("next", "advance to the next step"),
                .init("repeat", "hear the current step again"),
                .init("set a 5-minute timer", "start a countdown without taking your hands off the food"),
                .init("help", "list every command Stir understands"),
            ],
        ),
        CoachMarkStep(
            id: "exit",
            anchor: .voiceExitButton,
            placement: .below,
            title: "Drop back to taps",
            message: "If your hands free up, tap the X to leave Voice Mode. You can re-engage voice from the Cook Mode header any time.",
        ),
    ]
}
