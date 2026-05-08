// DeleteMyDataView
//
// SCA-61 — in-app CCPA right-to-delete surface.
//
// Privacy Policy §7.7 (2026-04-24) directed users to email
// privacy@getstir.app. State AGs + the SOC2 audit flagged email-only
// as friction-shaped barrier to the §7.2 right-to-delete; this screen
// satisfies the "in-app primary" requirement while the email path
// remains as a fallback for users who can't authenticate (account
// recovery, deceased-user requests by next-of-kin, etc.).
//
// Flow:
//   1. Plain-language explanation of what gets deleted (CloudKit zone +
//      Postgres operational rows + cross-system identifiers).
//   2. Two-step type-to-confirm — user must type "DELETE MY DATA"
//      verbatim. This is a friction gate; the keyboard's auto-correct
//      is disabled to stop the iOS Dictation UX from auto-capitalizing
//      a partial match into success.
//   3. POST /v1/users/delete-request — idempotent, server returns the
//      pending row id whether the call is the first or a duplicate.
//   4. Success state confirms the SLA (30 days, per Privacy Policy
//      §7.2) and offers the email path for inquiries.

import Foundation
import OSLog
import SwiftUI

@MainActor
struct DeleteMyDataView: View {
    @Environment(RootCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var confirmationText: String = ""
    @State private var submissionState: SubmissionState = .idle
    @FocusState private var confirmFocused: Bool

    private static let confirmationPhrase = "DELETE MY DATA"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                explanationCard
                confirmationCard
                actionRow
                fallbackCard
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.top, CGFloat.Stir.space3)
            .padding(.bottom, CGFloat.Stir.space7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Stir.paper50)
        .navigationTitle("Delete my data")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Delete my data")
                    .stirFont(.displaySm)
                    .foregroundStyle(Color.Stir.textPrimary)
            }
        }
        .toolbarBackground(Color.Stir.paper50, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    // MARK: - Sections

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
            Text("This deletes your account and all data Stir holds about you.")
                .stirFont(.bodyLg)
                .foregroundStyle(Color.Stir.textPrimary)

            VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
                bulletRow("Pantry, recipes, cooking history, and ratings (CloudKit)")
                bulletRow("Subscription record, quotas, and AI request logs (Stir backend)")
                bulletRow("Analytics, support tickets, and crash reports linked to you")
            }

            Text("Deletion completes within 30 days. Subscription auto-renew is canceled — manage refunds via the App Store.")
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.textSecondary)
        }
        .padding(CGFloat.Stir.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .stirCard()
    }

    private var confirmationCard: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
            Text("Type \(Self.confirmationPhrase) to confirm")
                .stirFont(.labelLg)
                .foregroundStyle(Color.Stir.textPrimary)

            TextField("", text: $confirmationText)
                .stirFont(.bodyLg)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
                .focused($confirmFocused)
                .padding(CGFloat.Stir.space3)
                .background(Color.Stir.paper100)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            confirmationMatches ? Color.Stir.ember600 : Color.Stir.ink300,
                            lineWidth: 1,
                        ),
                )

            if case let .failed(message) = submissionState {
                Text(message)
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.danger)
            }

            if case .submitted = submissionState {
                Text("Submitted. We'll email you when deletion is complete (within 30 days).")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.textSecondary)
            }
        }
        .padding(CGFloat.Stir.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .stirCard()
    }

    private var actionRow: some View {
        Button {
            Task { await submit() }
        } label: {
            HStack {
                if case .submitting = submissionState {
                    ProgressView()
                        .tint(Color.Stir.paper50)
                        .padding(.trailing, CGFloat.Stir.space2)
                }
                Text(actionTitle)
                    .stirFont(.labelLg)
                    .foregroundStyle(Color.Stir.paper50)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, CGFloat.Stir.space3Half)
            .background(actionBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!actionEnabled)
    }

    private var fallbackCard: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            Text("Need help?")
                .stirFont(.labelLg)
                .foregroundStyle(Color.Stir.textPrimary)
            Text("If you can't access this account, email privacy@getstir.app from the address tied to your subscription.")
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.textSecondary)
            Button {
                if let u = URL(string: "mailto:privacy@getstir.app?subject=Delete%20my%20data") {
                    UIApplication.shared.open(u)
                }
            } label: {
                Text("Email privacy@getstir.app")
                    .stirFont(.labelLg)
                    .foregroundStyle(Color.Stir.ember600)
            }
            .buttonStyle(.plain)
            .padding(.top, CGFloat.Stir.space2)
        }
        .padding(CGFloat.Stir.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .stirCard()
    }

    // MARK: - Helpers

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: CGFloat.Stir.space2) {
            Text("•")
                .stirFont(.bodyLg)
                .foregroundStyle(Color.Stir.textSecondary)
            Text(text)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var confirmationMatches: Bool {
        confirmationText.trimmingCharacters(in: .whitespacesAndNewlines) == Self.confirmationPhrase
    }

    private var actionEnabled: Bool {
        switch submissionState {
        case .idle, .failed:
            return confirmationMatches
        case .submitting, .submitted:
            return false
        }
    }

    private var actionTitle: String {
        switch submissionState {
        case .idle, .failed:
            return "Submit deletion request"
        case .submitting:
            return "Submitting…"
        case .submitted:
            return "Submitted"
        }
    }

    private var actionBackground: Color {
        actionEnabled ? Color.Stir.danger : Color.Stir.textTertiary
    }

    private func submit() async {
        guard confirmationMatches else { return }
        submissionState = .submitting
        do {
            let response = try await coordinator.submitDeletionRequest()
            Logger.settings.info("deletion request accepted; id=\(response.deletionRequestID, privacy: .public) state=\(response.state, privacy: .public) idempotent=\(response.idempotent ? "1" : "0", privacy: .public)")
            submissionState = .submitted
        } catch {
            let message: String
            if let stir = error as? StirError {
                switch stir {
                case .rateLimited:
                    message = "Too many attempts. Please try again later."
                case .networkUnreachable:
                    message = "Couldn't reach Stir. Check your connection and try again."
                case let .auth(reason, _):
                    message = "Session issue (\(reason.rawValue)). Please reopen the app."
                default:
                    message = "Submission failed. Please try again."
                }
            } else {
                message = "Submission failed. Please try again."
            }
            Logger.settings.error("deletion request failed: \(error.localizedDescription, privacy: .public)")
            submissionState = .failed(message)
        }
    }
}

// MARK: - Submission state

private enum SubmissionState: Equatable {
    case idle
    case submitting
    case submitted
    case failed(String)
}

// MARK: - Preview

#Preview {
    NavigationStack {
        DeleteMyDataView()
    }
}
