// InputField
//
// Styled text field with Stir focus + error treatment (Specs/Design-System.md
// §8.5). Wraps a SwiftUI TextField in a paper.100 container with
// adaptive border color and inline error text below.
//
// Visual grammar:
//   - 48pt height
//   - radius.md (12pt)
//   - paper.100 fill, 1pt ink.100 border at rest
//   - 1pt ember.600 border on focus
//   - 1pt crimson.600 border on error + inline crimson.600 body.sm error
//     text below the field
//
// Focus state is driven by `@FocusState` at the call site; the
// `isFocused` binding plumbs it into the component so the border
// animates without the component owning focus identity.
//
// Error state: non-nil `errorMessage` → crimson border + error text.
// Empty string does NOT trigger error — only nil vs non-nil. Match the
// spec pattern: validation error strings are meaningful; empty is
// neutral.

import SwiftUI
import UIKit

struct InputField: View {
    let placeholder: String
    @Binding var text: String
    let errorMessage: String?
    let isFocused: Bool
    let keyboardType: UIKeyboardType
    let autocapitalization: TextInputAutocapitalization
    let submitLabel: SubmitLabel
    let onSubmit: (() -> Void)?

    init(
        placeholder: String,
        text: Binding<String>,
        errorMessage: String? = nil,
        isFocused: Bool = false,
        keyboardType: UIKeyboardType = .default,
        autocapitalization: TextInputAutocapitalization = .sentences,
        submitLabel: SubmitLabel = .done,
        onSubmit: (() -> Void)? = nil,
    ) {
        self.placeholder = placeholder
        self._text = text
        self.errorMessage = errorMessage
        self.isFocused = isFocused
        self.keyboardType = keyboardType
        self.autocapitalization = autocapitalization
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space1 + 2) { // 6pt
            TextField(placeholder, text: $text)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink900)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(autocapitalization)
                .submitLabel(submitLabel)
                .onSubmit { onSubmit?() }
                .padding(.horizontal, CGFloat.Stir.space4)
                .frame(height: 48)
                .background(
                    RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                        .fill(Color.Stir.paper100),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: borderWidth),
                )

            if let errorMessage {
                Text(errorMessage)
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.crimson600)
                    .accessibilityHint("Error")
            }
        }
    }

    private var borderColor: Color {
        if errorMessage != nil {
            return Color.Stir.crimson600
        } else if isFocused {
            return Color.Stir.ember600
        } else {
            return Color.Stir.divider
        }
    }

    /// Focused + error states take a slightly thicker border so the
    /// state change reads at arm's length (Spec §1 "Legibility under
    /// distraction"). Rest is 1pt hairline.
    private var borderWidth: CGFloat {
        (errorMessage != nil || isFocused) ? 1.5 : 1
    }
}

// MARK: - Previews

#Preview("InputField — light") {
    InputFieldGallery()
        .preferredColorScheme(.light)
}

#Preview("InputField — dark") {
    InputFieldGallery()
        .preferredColorScheme(.dark)
}

private struct InputFieldGallery: View {
    @State private var empty = ""
    @State private var filled = "spinach, feta, olive oil"
    @State private var focused = "https://smittenkitchen.com/…"
    @State private var errored = "not-a-url"

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space4) {
            label("Empty — resting")
            InputField(placeholder: "What's in your kitchen?", text: $empty)

            label("Filled — resting")
            InputField(placeholder: "Ingredients", text: $filled)

            label("Focused")
            InputField(placeholder: "Recipe URL", text: $focused, isFocused: true)

            label("Error")
            InputField(
                placeholder: "Recipe URL",
                text: $errored,
                errorMessage: "That doesn't look like a valid URL.",
            )

            Spacer()
        }
        .padding(CGFloat.Stir.space4)
        .frame(width: 390, height: 844)
        .background(Color.Stir.paper50)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.textTertiary)
    }
}
