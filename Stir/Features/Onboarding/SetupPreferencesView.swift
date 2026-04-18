// SetupPreferencesView
//
// Step 1 of onboarding: dietary rules + diets + goals. Tap-togglable chips.
// All three sections are optional — user can continue without selecting any.

import SwiftUI

struct SetupPreferencesView: View {
    @Bindable var viewModel: OnboardingViewModel
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What should we never serve?")
                        .font(.title.weight(.semibold))
                    Text("Pick any that apply — these are hard rules.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                section(title: "Allergies", tint: .red) {
                    chipsGrid(options: AllergenOption.allCases, selection: $viewModel.selectedAllergens, displayName: \.displayName)
                }

                section(title: "Diet", tint: .green) {
                    chipsGrid(options: DietOption.allCases, selection: $viewModel.selectedDiets, displayName: \.displayName)
                }

                section(title: "Goals", subtitle: "Soft preferences — bias, not block.", tint: .blue) {
                    chipsGrid(options: GoalOption.allCases, selection: $viewModel.selectedGoals, displayName: \.displayName)
                }

                Spacer(minLength: 80)  // leave room for safe-area-inset button
            }
            .padding()
        }
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .background(.thinMaterial)
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        subtitle: String? = nil,
        tint: Color,
        @ViewBuilder content: () -> Content,
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            content()
                .tint(tint)
        }
    }
}

// MARK: - Chips

private struct ChipToggle<Value: Hashable>: View {
    let value: Value
    let displayName: String
    @Binding var selection: Set<Value>

    var isSelected: Bool { selection.contains(value) }

    var body: some View {
        Button {
            if isSelected { selection.remove(value) } else { selection.insert(value) }
        } label: {
            Text(displayName)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.secondarySystemBackground))),
                )
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .overlay(
                    Capsule().stroke(
                        isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.separator)),
                        lineWidth: 1,
                    ),
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension View {
    func chipsGrid<Value: Hashable>(
        options: [Value],
        selection: Binding<Set<Value>>,
        displayName: KeyPath<Value, String>,
    ) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(options, id: \.self) { option in
                ChipToggle(
                    value: option,
                    displayName: option[keyPath: displayName],
                    selection: selection,
                )
            }
        }
    }
}

// MARK: - Simple flow layout for chips (SwiftUI Layout protocol, iOS 16+)

private struct FlowLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat = 8) { self.spacing = spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width, currentX > 0 {
                currentY += lineHeight + spacing
                currentX = 0
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalHeight = currentY + lineHeight
        }
        return CGSize(width: width == .infinity ? currentX : width, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout (),
    ) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentY += lineHeight + spacing
                currentX = bounds.minX
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(size),
            )
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
