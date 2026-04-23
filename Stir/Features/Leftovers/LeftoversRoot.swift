// LeftoversRoot
//
// Orchestrates the two-stage Leftovers flow: prompt → (solving) →
// options. Owns the LeftoversSessionViewModel lifetime. Presented as
// a fullScreenCover from whichever screen hosts the Cook Mode exit
// path (typically CookModeRoot after OutcomeFeedback submits).
//
// Dismissal:
//   - User taps "None" / "Close" / "Not tomorrow" → onDismiss()
//   - User selects a dish on the options screen → onSelect(dish)
//
// The parent decides what to do with the selected dish (persist as a
// new RecipePlan, deep-link to DishPreview, etc.) — this root is
// presentation-only.

import SwiftUI

struct LeftoversRoot: View {
    @Bindable var viewModel: LeftoversSessionViewModel
    let onSelect: (DishCard) -> Void
    let onDismiss: () -> Void

    var body: some View {
        switch viewModel.stage {
        case .prompt:
            LeftoversPromptView(
                viewModel: viewModel,
                onFindIdea: { await viewModel.findFollowUpIdea() },
                onDismiss: onDismiss,
            )
        case .solving, .options, .error:
            NavigationStack {
                LeftoversSolveView(
                    viewModel: viewModel,
                    onSelect: onSelect,
                    onDismiss: onDismiss,
                )
                .navigationTitle("Use what's left")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", action: onDismiss)
                            .foregroundStyle(Color.Stir.ink700)
                    }
                }
            }
        }
    }
}
