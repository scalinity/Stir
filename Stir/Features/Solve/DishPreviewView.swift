// DishPreviewView
//
// End-of-step-3 landing page. Shows the chosen dish in full: ingredients,
// steps, missing-from-pantry callouts. "Start Cooking" CTA is intentionally
// disabled — step 4 wires it to Cook Mode.

import SwiftUI

struct DishPreviewView: View {
    @Bindable var viewModel: SolveViewModel
    let dish: DishCard

    @State private var toast: String?

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
        .overlay(alignment: .top) { toastView }
        .onAppear {
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
        Button {
            toast = "Cook Mode lands in the next step."
        } label: {
            Text("Start Cooking")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.gray.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let message = toast {
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.85), in: Capsule())
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { self.toast = nil }
                }
        }
    }
}
