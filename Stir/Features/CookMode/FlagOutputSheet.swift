// FlagOutputSheet — discreet "Report issue" sheet for flagging a bad AI
// output. Step 8 Phase 3. Surfaced from CookMode's overflow menu + from
// SubstitutionResultView footer. Posts to /v1/ops/flag-output via
// FlagOutputService; server-side dedup means repeat submissions return
// the same id with dedup=true but the UX is the same "Thanks" regardless.
//
// Design constraint (from Daniel's step-8 prompt): DISCREET. Single text
// field for reason, Submit button, confirmation snackbar. No emoji, no
// hero layout — this is a utility, not a feature.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct FlagOutputSheet: View {
    let featureKey: FlagOutputService.FeatureKey
    let requestID: String
    let contextSnapshot: [String: AnyEncodable]?
    let flagOutputService: FlagOutputService

    /// Called with the submission result. Parent dismisses the sheet +
    /// shows a "Thanks — this helps us improve" toast on success.
    let onDone: @MainActor (Result<FlagOutputService.FlagOutputResponse, Error>) -> Void

    @State private var reason: String = ""
    @State private var isSubmitting: Bool = false
    @State private var submissionError: String? = nil
    @Environment(\.dismiss) private var dismiss

    private let maxChars = 500

    init(
        featureKey: FlagOutputService.FeatureKey,
        requestID: String,
        contextSnapshot: [String: AnyEncodable]? = nil,
        flagOutputService: FlagOutputService,
        onDone: @escaping @MainActor (Result<FlagOutputService.FlagOutputResponse, Error>) -> Void,
    ) {
        self.featureKey = featureKey
        self.requestID = requestID
        self.contextSnapshot = contextSnapshot
        self.flagOutputService = flagOutputService
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "What went wrong?",
                        text: $reason,
                        axis: .vertical,
                    )
                    .lineLimit(3...6)
                    .disabled(isSubmitting)
                    .accessibilityLabel("Describe the issue")
                } header: {
                    Text("Help us improve Stir")
                } footer: {
                    // W30 (FD1 #10): Dynamic Type AX5 safety. The footer's
                    // default Text layout wraps "/500 characters" and pushes
                    // the TextField up, potentially sliding the Submit button
                    // behind the keyboard. One-line + scale-to-fit keeps the
                    // CTA anchored.
                    Text("\(reason.count)/\(maxChars) characters")
                        .foregroundStyle(reason.count > maxChars ? .red : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityLabel("\(reason.count) of \(maxChars) characters")
                }

                if let err = submissionError {
                    Section {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.footnote)
                            // W31 (FD1 #11): announce the error via VoiceOver
                            // when it appears so keyboard-only / screen-reader
                            // users aren't left staring at a silently-disabled
                            // Submit button.
                            .accessibilityAddTraits(.isStaticText)
                            .accessibilityLabel("Submission error: \(err)")
                    }
                }
            }
            // Keep `.navigationTitle` for the implicit back-chevron
            // label any deeper pushed screen reads, plus VoiceOver —
            // visible chrome is `.stirTopBar` below.
            .navigationTitle("Report issue")
            .navigationBarTitleDisplayMode(.inline)
            // SCA-457: custom top bar escapes iOS 26 Liquid Glass.
            .stirTopBar(
                title: "Report issue",
                leading: {
                    StirTopBarCloseButton(isEnabled: !isSubmitting) { dismiss() }
                },
                trailing: {
                    StirTopBarTextButton(
                        "Submit",
                        emphasis: .prominent,
                        isEnabled: canSubmit,
                    ) { Task { await submit() } }
                },
            )
        }
    }

    private var canSubmit: Bool {
        !isSubmitting
            && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && reason.count <= maxChars
    }

    @MainActor
    private func submit() async {
        isSubmitting = true
        submissionError = nil
        defer { isSubmitting = false }

        do {
            let response = try await flagOutputService.flagOutput(
                featureKey: featureKey,
                requestID: requestID,
                flagReason: reason,
                contextSnapshot: contextSnapshot,
            )
            onDone(.success(response))
            dismiss()
        } catch {
            // S15 (FD1 #15): error-code-aware copy. Pre-fix was a single
            // "check your connection" string regardless of whether the
            // failure was NET-01, AUTH-01 (expired mid-sheet), VAL-01
            // (500-char bypass), or RATE-01. Map to user-meaningful copy.
            submissionError = userCopy(for: error)
            onDone(.failure(error))

            // W31: explicit VoiceOver announcement when the error appears.
            // .accessibilityLabel above handles the re-read after focus,
            // but a .announcement notification triggers the read even if
            // focus doesn't move back to the error element.
            #if canImport(UIKit)
            UIAccessibility.post(notification: .announcement, argument: submissionError)
            #endif
        }
    }

    private func userCopy(for error: any Error) -> String {
        guard let stir = error as? StirError else {
            return "Couldn't submit. Please try again."
        }
        switch stir {
        case .networkUnreachable:
            return "Check your connection and try again."
        case .auth:
            return "Your session expired. Sign out and back in, then retry."
        case .validation(_, let message):
            // VAL-01 here is almost always "reason too long"; surface the
            // specific message if we have one.
            return message.isEmpty
                ? "Please shorten your description and try again."
                : message
        case .rateLimited:
            return "Too many reports just now. Please wait a minute and try again."
        default:
            return "Couldn't submit. Please try again."
        }
    }
}
