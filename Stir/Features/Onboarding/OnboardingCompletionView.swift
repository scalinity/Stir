// OnboardingCompletionView
//
// Transitional "setting up your kitchen" surface between Setup 2 and
// Tonight Home (mockup 02 §"Completion transition"). On appear:
//   1. Calls `viewModel.completeOnboarding()` — durably sets
//      HouseholdProfile.onboardingCompleted=true. If the user kills
//      the app during the 1.5s dwell, they still count as completed
//      and don't re-enter onboarding on next launch (decision b).
//   2. Fires the `onboarding_completed` PostHog event in commit 3 —
//      this commit leaves the emission site as a TODO marker. Event
//      payload includes `duration_sec` + `skipped_steps` per Spec §15.
//   3. Starts a 1.5s dwell via `.task { try? Task.sleep(...) }`, then
//      invokes `onFinished` to flip coordinator phase to `.ready`.
//
// Visual grammar:
//   - Circular progress ring (96pt) with ember sweep at ~85% and a
//     centered ember checkmark — the "almost there" visual metaphor.
//   - displayMd title "Setting up your kitchen"
//   - bodyMd personalized body referencing the user's chosen diets +
//     goals (falls back to generic copy if the user skipped through
//     Setup 1 with zero selections).
//   - Checklist row (3 items):
//       ✓ Preferences saved  (sage)
//       ✓ Kitchen profile ready  (sage)
//       ⟳ Loading a starter meal…  (70% opacity, ember partial-arc)
//
// Reduce Motion: the checkmark-ring static-stroke renders regardless;
// only the "loading a starter meal" row's spinner animates. With
// Reduce Motion on, the spinner stays static.

import SwiftUI

struct OnboardingCompletionView: View {
    @Bindable var viewModel: OnboardingViewModel
    let onFinished: () -> Void

    @State private var errorMessage: String?

    /// Dwell between completion-save and onFinished advance. Matches
    /// mockup annotation "roughly 1.5 seconds". Short enough to feel
    /// intentional, long enough to read the personalized summary.
    private static let dwellDuration: Duration = .milliseconds(1500)

    var body: some View {
        VStack(spacing: CGFloat.Stir.space6) {
            Spacer()
            ringWithCheck
            titleBlock
            checklist
            Spacer()
        }
        .padding(.horizontal, CGFloat.Stir.space6 + CGFloat.Stir.space1) // 36pt
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Stir.paper50)
        .navigationBarBackButtonHidden(true)
        .task {
            do {
                try viewModel.completeOnboarding()
            } catch {
                errorMessage = ErrorPresenter.present(.sync01).message
                return
            }
            // TODO(commit 3): fire PostHog `onboarding_completed`
            // event here — BEFORE the dwell so a user who kills during
            // the 1.5s still counts. Properties: duration_sec +
            // skipped_steps (from viewModel.skippedSteps).
            try? await Task.sleep(for: Self.dwellDuration)
            onFinished()
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } },
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var ringWithCheck: some View {
        ZStack {
            Circle()
                .stroke(Color.Stir.ink100, lineWidth: 3)
                .frame(width: 96, height: 96)

            // ~85% arc sweep in ember.600 per mockup. Rendered as a
            // static trim rather than a rotating sweep — the metaphor
            // is "almost ready", not "still loading".
            Circle()
                .trim(from: 0.0, to: 0.85)
                .stroke(
                    Color.Stir.ember600,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round),
                )
                .frame(width: 96, height: 96)
                .rotationEffect(.degrees(-90))

            Image.Stir.check
                .font(.system(size: 36, weight: .semibold)) // justification: 36pt hero checkmark inside the 96pt ring — one-off hero size per §4.1
                .foregroundStyle(Color.Stir.ember600)
        }
        .accessibilityElement()
        .accessibilityLabel("Setup complete")
    }

    private var titleBlock: some View {
        VStack(spacing: CGFloat.Stir.space3 + 2) { // 14pt
            Text("Setting up your kitchen")
                .stirFont(.displayMd)
                .foregroundStyle(Color.Stir.ink900)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(personalizedBody)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink500)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
    }

    /// Personalized body copy referencing the user's Setup 1 selections.
    /// Falls back to generic copy when the user skipped Setup 1.
    private var personalizedBody: String {
        let dietBits = dietDescription
        let goalBits = goalDescription

        switch (dietBits.isEmpty, goalBits.isEmpty) {
        case (true, true):
            return "Loading a starter meal based on sensible defaults. You can edit preferences anytime in Settings."
        case (true, false):
            return "Tuning suggestions around your \(goalBits) goals."
        case (false, true):
            return "Tuning suggestions to your \(dietBits) diet."
        case (false, false):
            return "Tuning suggestions to your \(dietBits) diet and your \(goalBits) goals."
        }
    }

    private var dietDescription: String {
        var parts: [String] = []
        for diet in viewModel.selectedDiets.sorted(by: { $0.rawValue < $1.rawValue }) {
            parts.append(diet.displayName.lowercased())
        }
        for allergen in viewModel.selectedAllergens.sorted(by: { $0.rawValue < $1.rawValue }) {
            parts.append("\(allergen.displayName.lowercased())-free")
        }
        return parts.joined(separator: ", ")
    }

    private var goalDescription: String {
        let parts = viewModel.selectedGoals
            .sorted(by: { $0.rawValue < $1.rawValue })
            .map { $0.displayName.lowercased() }
        return parts.joined(separator: ", ")
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space3 - 2) { // 10pt
            ChecklistRow(
                text: "Preferences saved",
                status: .done,
            )
            ChecklistRow(
                text: "Kitchen profile ready",
                status: .done,
            )
            ChecklistRow(
                text: "Loading a starter meal…",
                status: .inProgress,
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, CGFloat.Stir.space2)
    }
}

// MARK: - ChecklistRow

private struct ChecklistRow: View {
    enum Status { case done, inProgress }
    let text: String
    let status: Status

    @State private var rotationAngle: Angle = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: CGFloat.Stir.space3 - 2) { // 10pt
            icon
            Text(text)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink700)
        }
        .opacity(status == .inProgress ? 0.7 : 1.0)
        .accessibilityLabel(status == .done ? "\(text), complete" : "\(text), in progress")
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case .done:
            Image.Stir.success
                .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                .foregroundStyle(Color.Stir.sage600)
        case .inProgress:
            ZStack {
                Circle()
                    .stroke(Color.Stir.ink100, lineWidth: 2)
                Circle()
                    .trim(from: 0.0, to: 0.25)
                    .stroke(
                        Color.Stir.ember600,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round),
                    )
                    .rotationEffect(rotationAngle)
            }
            .frame(width: 16, height: 16)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(
                    .linear(duration: 0.9).repeatForever(autoreverses: false),
                ) {
                    rotationAngle = .degrees(360)
                }
            }
        }
    }
}
