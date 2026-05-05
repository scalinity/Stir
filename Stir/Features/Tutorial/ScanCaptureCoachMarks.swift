// ScanCaptureCoachMarks
//
// Coach-mark sequence for the camera capture screen. Two steps:
// framing tip + shutter prompt. Step 2 is action-gated on the real
// shutter tap so the tutorial never asks for two taps.

import Foundation

enum ScanCaptureCoachMarks {
    static let steps: [CoachMarkStep] = [
        CoachMarkStep(
            id: "framing",
            placement: .center,
            title: "Frame your kitchen",
            message: "Get pantry shelves, the fridge interior, and the counter all in one shot if you can — Stir reads the labels for you. Lighting matters more than steadiness.",
        ),
        CoachMarkStep(
            id: "shutter",
            anchor: .scanShutter,
            placement: .above,
            title: "Tap the shutter",
            message: "When you're ready, tap the shutter. Stir freezes the frame and parses what it sees.",
            requiredAction: .shutterTap,
        ),
    ]
}
