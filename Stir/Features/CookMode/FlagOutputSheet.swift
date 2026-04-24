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
                    Text("\(reason.count)/\(maxChars) characters")
                        .foregroundStyle(reason.count > maxChars ? .red : .secondary)
                        .accessibilityLabel("\(reason.count) of \(maxChars) characters")
                }

                if let err = submissionError {
                    Section {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Report issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit)
                }
            }
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
            submissionError = "Couldn't submit. Check your connection and try again."
            onDone(.failure(error))
        }
    }
}
