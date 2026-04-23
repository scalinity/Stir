// ErrorPresenter
//
// Maps `ErrorCode` to the user-visible copy in spec §6. ALL user-facing error
// copy originates here — never inline copy in view files, and never concatenate
// server `message` into user copy (server `message` is dev-facing per CLAUDE.md
// §"VAL-01 response shape").
//
// When iOS receives a typed server error, it passes the code through
// `ErrorPresenter.present(_:)` to get the rendered `UserFacingError`, then
// displays it via whatever error surface (banner, toast, full-screen).

import Foundation

struct UserFacingError: Sendable, Equatable {
    let code: ErrorCode
    /// Short headline (max ~30 chars). Used in toast/banner titles.
    let title: String
    /// Body copy exactly as spec §6. Multi-line allowed.
    let message: String
    /// Primary action button copy. Optional for purely informational banners.
    let primaryAction: String?
    /// Secondary action button copy.
    let secondaryAction: String?
    /// If true, iOS should render a prominent error surface (full-screen or
    /// toast-at-top). If false, render as an inline banner.
    let blocking: Bool
}

enum ErrorPresenter {
    static func present(_ error: StirError) -> UserFacingError {
        present(error.presentableCode)
    }

    static func present(_ code: ErrorCode) -> UserFacingError {
        switch code {
        case .net01:
            return UserFacingError(
                code: .net01,
                title: "Can't reach Stir",
                message: "Couldn't reach Stir right now. Check your connection and try again.",
                primaryAction: "Retry",
                secondaryAction: "Go Back",
                blocking: false,
            )
        case .ai01:
            return UserFacingError(
                code: .ai01,
                title: "Dinner planning paused",
                message: "Dinner planning is temporarily unavailable. Try again in a moment or cook a saved meal.",
                primaryAction: "Retry",
                secondaryAction: "Open Saved Meals",
                blocking: false,
            )
        case .ai02:
            return UserFacingError(
                code: .ai02,
                title: "Quick review needed",
                message: "I'm not confident about a few ingredients. Confirm them to keep going.",
                primaryAction: "Review Ingredients",
                secondaryAction: nil,
                blocking: false,
            )
        case .ai03:
            return UserFacingError(
                code: .ai03,
                title: "Still working…",
                message: "This is taking longer than expected.",
                primaryAction: "Keep Waiting",
                secondaryAction: "Cook Saved",
                blocking: false,
            )
        case .aiVoice01:
            return UserFacingError(
                code: .aiVoice01,
                title: "Voice mode reduced",
                message: "Voice mode running in reduced quality — still here to help.",
                primaryAction: "Continue",
                secondaryAction: "Use Taps",
                blocking: false,
            )
        case .import01:
            return UserFacingError(
                code: .import01,
                title: "Import needs a hand",
                message: "I couldn't turn that recipe into clean steps yet.",
                primaryAction: "Edit Manually",
                secondaryAction: "Cancel",
                blocking: false,
            )
        case .permCam01:
            return UserFacingError(
                code: .permCam01,
                title: "Camera off",
                message: "Camera access is off. Turn it on to scan your kitchen.",
                primaryAction: "Open Settings",
                secondaryAction: "Use Sample Photo",
                blocking: false,
            )
        case .permMic01:
            return UserFacingError(
                code: .permMic01,
                title: "Microphone off",
                message: "Microphone access is off. You can keep cooking with taps, or turn on the mic in Settings.",
                primaryAction: "Keep Cooking",
                secondaryAction: "Open Settings",
                blocking: false,
            )
        case .permPhoto01:
            return UserFacingError(
                code: .permPhoto01,
                title: "Photos off",
                message: "Photos access is off. Enable it to import a screenshot or recipe photo.",
                primaryAction: "Open Settings",
                secondaryAction: "Paste Link Instead",
                blocking: false,
            )
        case .permRem01:
            return UserFacingError(
                code: .permRem01,
                title: "Reminders off",
                message: "Reminders access is off. Your grocery list will stay in Stir until you enable Reminders.",
                primaryAction: "Keep In App",
                secondaryAction: "Open Settings",
                blocking: false,
            )
        case .sync01:
            return UserFacingError(
                code: .sync01,
                title: "Local only mode",
                message: "iCloud Sync isn't available. Stir will work on this device only for now.",
                primaryAction: "Continue Locally",
                secondaryAction: "Learn More",
                blocking: false,
            )
        case .rate01:
            return UserFacingError(
                code: .rate01,
                title: "Monthly limit reached",
                message: "You've used all of this month's available actions for your plan.",
                primaryAction: "Upgrade",
                secondaryAction: "See Reset Date",
                blocking: false,
            )
        case .bill01:
            return UserFacingError(
                code: .bill01,
                title: "Subscription unclear",
                message: "We couldn't confirm your subscription right now.",
                primaryAction: "Restore Purchases",
                secondaryAction: "Retry",
                blocking: false,
            )
        case .pay01:
            return UserFacingError(
                code: .pay01,
                title: "Purchase failed",
                message: "Purchase didn't go through. You weren't charged.",
                primaryAction: "Try Again",
                secondaryAction: "Choose Another Plan",
                blocking: false,
            )
        case .entVoice01:
            return UserFacingError(
                code: .entVoice01,
                title: "Voice is Premium",
                message: "Cook Mode voice is a Premium feature. Try it free for 7 days.",
                primaryAction: "Start Trial",
                secondaryAction: "See Plans",
                blocking: true,
            )
        case .entMultiImage01:
            return UserFacingError(
                code: .entMultiImage01,
                title: "Multi-image is Pro",
                message: "Multi-image scan is available on Pro. Upgrade to scan your whole kitchen at once.",
                primaryAction: "See Plans",
                secondaryAction: "Continue with one",
                blocking: true,
            )
        case .entLeftovers01:
            return UserFacingError(
                code: .entLeftovers01,
                title: "Leftovers is Premium",
                message: "Turn leftovers into a next meal with Stir Premium. Try it free for 7 days.",
                primaryAction: "Start Trial",
                secondaryAction: "See Plans",
                blocking: true,
            )
        case .voiceSession01:
            // VOICE-SESSION-01 is lifecycle, not entitlement: the voice
            // session bound to this session_id is no longer valid (missing,
            // closed, or supersedes by a newer mint). Voice drivers catch
            // this internally and fall back to C.3 text mode without user
            // copy on the happy path — this arm is the failsafe if the
            // error reaches the app-level error surface uncaught.
            return UserFacingError(
                code: .voiceSession01,
                title: "Voice session ended",
                message: "Your voice session was interrupted. Restart Cook Mode to keep going with voice.",
                primaryAction: "Restart",
                secondaryAction: "Continue without voice",
                blocking: false,
            )
        case .val01:
            return UserFacingError(
                code: .val01,
                title: "Something went wrong",
                message: "Something went wrong. Please try again or contact support if this keeps happening.",
                primaryAction: "Retry",
                secondaryAction: "Contact Support",
                blocking: false,
            )
        case .auth01:
            // AUTH-01 is internal — iOS auto-re-bootstraps silently. This
            // entry exists as a fallback if re-bootstrap fails and the error
            // surfaces anyway (SupabaseSessionClient normally downgrades a
            // failed retry to NET-01). If a user ever does see this, the
            // silent retry already failed, so copy reflects that honestly
            // rather than claiming the sign-in is in progress.
            return UserFacingError(
                code: .auth01,
                title: "Couldn't refresh session",
                message: "We couldn't refresh your sign-in. Check your connection and try again.",
                primaryAction: "Retry",
                secondaryAction: nil,
                blocking: false,
            )
        case .methodNotAllowed01:
            // 405 only fires when iOS sends the wrong HTTP verb — a
            // build-time bug that should be caught in review, not user
            // copy. Fall back to a generic retry surface in case telemetry
            // ever routes it to UI.
            return UserFacingError(
                code: .methodNotAllowed01,
                title: "Something went wrong",
                message: "Something went wrong. Please try again or contact support if this keeps happening.",
                primaryAction: "Retry",
                secondaryAction: "Contact Support",
                blocking: false,
            )
        }
    }
}
