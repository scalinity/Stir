// DishPreviewView
//
// End-of-step-3 landing page. Shows the chosen dish in full: ingredients,
// steps, missing-from-pantry callouts. "Start Cooking" CTA is intentionally
// disabled — step 4 wires it to Cook Mode.

import SwiftUI

struct DishPreviewView: View {
    @Bindable var viewModel: SolveViewModel
    let dish: DishCard

    @State private var hasCapturedSelection = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                missingIngredientsSection
                ingredientsSection
                stepsSection
            }
            .padding()
        }
        .navigationTitle(dish.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            startCookingBar
                .padding(.horizontal)
                .padding(.bottom, 8)
                .background(.bar)
        }
        .onAppear {
            // Guard against re-capture on back-nav re-entry. NavigationStack
            // creates a fresh DishPreviewView on each push so @State resets,
            // meaning this fires exactly once per push — never on subsequent
            // .onAppear calls triggered by deeper navigation returning.
            guard !hasCapturedSelection else { return }
            hasCapturedSelection = true
            viewModel.selectDish(dish)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(dish.totalTimeMinutes) min", systemImage: "clock")
                Spacer()
                Label("Rank \(dish.rank)", systemImage: "trophy")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Text(dish.whyItFits)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            if !dish.reasoningSummary.isEmpty {
                Text(dish.reasoningSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var missingIngredientsSection: some View {
        if dish.missingIngredientCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Label("Missing from your pantry", systemImage: "cart")
                    .font(.headline)
                Text("We'll flag these — pick them up or swap via substitution later.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("\(dish.missingIngredientCount) item\(dish.missingIngredientCount == 1 ? "" : "s")")
                    .font(.subheadline.weight(.medium))
            }
            .padding()
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ingredients")
                .font(.headline)
            Text("Serves \(dish.recipePlan.servings)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(dish.recipePlan.ingredients.enumerated()), id: \.offset) { _, ing in
                    HStack(alignment: .top, spacing: 8) {
                        Text(ing.amountText)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Text(ing.displayName + (ing.isOptional ? "  (optional)" : ""))
                            .font(.subheadline)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Steps")
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(dish.recipePlan.steps.enumerated()), id: \.offset) { idx, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(idx + 1).")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.instructionText)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                            if let secs = step.timerSeconds, secs > 0 {
                                Label("\(secs / 60) min timer", systemImage: "timer")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var startCookingBar: some View {
        // Button looks primary but step-3 can't cook — mark it truly
        // disabled so VoiceOver doesn't announce it as an active button
        // and sighted users can't tap a dead control. Cook Mode wires
        // the real action in step 4.
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .accessibilityHidden(true)
            Text("Cook Mode available in the next update")
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cook Mode available in the next update")
        .accessibilityHint("This dish is ready to cook once Cook Mode ships.")
    }

    // Toast surface removed — the old one fired on tap of the now-disabled
    // "Start Cooking" bar and the bar no longer has a tap action (FD1-4).
    @ViewBuilder
    private var toastView: some View {
        EmptyView()
    }
}
