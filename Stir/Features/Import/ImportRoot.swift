// ImportRoot
//
// Orchestrates the import flow stages into a single fullScreenCover-
// ready root. The caller (e.g. Tonight Home's "Import recipe" tile,
// or Saved's "+") presents this and observes `onCompleted(recipePlanID)`
// to route the user to the just-imported recipe in Saved.

import SwiftUI

struct ImportRoot: View {
    @Bindable var viewModel: ImportViewModel
    let onDismiss: () -> Void
    let onCompleted: (UUID) -> Void

    var body: some View {
        switch viewModel.stage {
        case .idle, .submitting:
            ImportEntryView(viewModel: viewModel, onDismiss: onDismiss)
        case .review(let recipe, let parseQuality):
            ImportReviewView(
                viewModel: viewModel,
                recipe: recipe,
                parseQuality: parseQuality,
                onDismiss: onDismiss,
            )
        case .queued(let jobID):
            QueuedView(jobID: jobID, onDismiss: onDismiss)
        case .saving:
            ImportEntryView(viewModel: viewModel, onDismiss: onDismiss)  // overlay handled within
        case .saved(let planID):
            SavedView(recipePlanID: planID, onOpen: {
                onCompleted(planID)
            }, onDismiss: onDismiss)
        case .error(let code, let message):
            ErrorView(code: code, message: message, onRetry: {
                // Return to entry so the user can try a different method.
                viewModel.cancelImport()
            })
        }
    }
}

// MARK: - Queued (async import)

private struct QueuedView: View {
    let jobID: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .tint(Color.Stir.ember600)
            Text("Working on it…")
                .stirFont(.displayMd)
                .foregroundStyle(Color.Stir.ink900)
            Text("Big recipes take a minute. We'll notify you when it's ready.")
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink500)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button(action: onDismiss) {
                Text("Done")
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: 160, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.Stir.ember600),
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Stir.paper50.ignoresSafeArea())
    }
}

// MARK: - Saved

private struct SavedView: View {
    let recipePlanID: UUID
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.Stir.sage100)
                    .frame(width: 72, height: 72)
                Image(systemName: "checkmark")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color.Stir.sage600)
            }
            Text("Saved.")
                .stirFont(.displayLg)
                .foregroundStyle(Color.Stir.ink900)
            Text("Find it in your Saved library anytime.")
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink500)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            VStack(spacing: 10) {
                Button(action: onOpen) {
                    Text("Open recipe")
                        .stirFont(.labelLg)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.Stir.ember600),
                        )
                }
                Button(action: onDismiss) {
                    Text("Done")
                        .stirFont(.labelLg)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.Stir.ink700)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Stir.paper50.ignoresSafeArea())
    }
}

// MARK: - Error

private struct ErrorView: View {
    let code: String
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.Stir.rust600)
                Text(code)
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.rust600)
            }
            Text("Couldn't import that recipe.")
                .stirFont(.displayMd)
                .foregroundStyle(Color.Stir.ink900)
            Text(message)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink700)
            Button(action: onRetry) {
                Text("Try again")
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: 140, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.Stir.ember600),
                    )
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.Stir.paper50.ignoresSafeArea())
    }
}
