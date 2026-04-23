// ImportEntryView
//
// Step-7 import entry screen matching mockup 11 screen 1. Serif
// headline + optional URL field + three import-method cards (Photo,
// Camera not-in-scope, Paste text) + privacy note + primary CTA.
//
// Flow:
//   URL entered → submit → stage.submitting → review OR error
//   Photo picked → OCR → submit → stage.submitting → review OR error
//   Text pasted → submit → stage.submitting → review OR error
//
// Camera capture deferred to a follow-up commit (requires the existing
// AVFoundation capture session plumbing from Scan reused here — more
// scope than v1 warrants). Photo picker uses PhotosPicker (iOS 16+).

import PhotosUI
import SwiftUI

struct ImportEntryView: View {
    @Bindable var viewModel: ImportViewModel
    let onDismiss: () -> Void

    @State private var urlText: String = ""
    @State private var pastedText: String = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var showPasteSheet: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    urlField
                    orDivider
                    methodCards
                    privacyNote
                    Spacer(minLength: 30)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
            .background(Color.Stir.paper50.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { footer }
            .navigationTitle("Import recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onDismiss)
                        .foregroundStyle(Color.Stir.ink700)
                        .accessibilityLabel("Close")
                        .accessibilityHint("Cancels the import and closes this screen")
                }
            }
            .onChange(of: pickerItem) { _, newItem in
                if let newItem { Task { await handlePicked(newItem) } }
            }
            .sheet(isPresented: $showPasteSheet) {
                PasteSheet(text: $pastedText) {
                    showPasteSheet = false
                    Task { await viewModel.submitPastedText(pastedText) }
                }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bring anything in.")
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .tracking(-0.56)
                .foregroundStyle(Color.Stir.ink900)
            Text("Stir parses the recipe and adapts it to your kitchen.")
                .font(.system(size: 14))
                .foregroundStyle(Color.Stir.ink500)
                .lineLimit(2)
        }
    }

    private var urlField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Link")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(urlText.isEmpty ? Color.Stir.ink500 : Color.Stir.ember600)
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.Stir.ink500)
                TextField("nytimes.com/recipes/…", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Color.Stir.ink900)
                    .accessibilityLabel("Recipe URL")
                    .accessibilityHint("Paste a URL to a recipe you want to import")
                if !urlText.isEmpty {
                    Button { urlText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.Stir.ink300)
                    }
                    .accessibilityLabel("Clear URL")
                    .accessibilityHint("Clears the URL field")
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    urlText.isEmpty ? Color.Stir.ink100 : Color.Stir.ember600,
                    lineWidth: urlText.isEmpty ? 1 : 1.5,
                ),
        )
    }

    private var orDivider: some View {
        Text("Or")
            .font(.system(size: 11, weight: .bold))
            .tracking(1.32)
            .textCase(.uppercase)
            .foregroundStyle(Color.Stir.ink500)
            .padding(.top, 4)
    }

    private var methodCards: some View {
        VStack(spacing: 8) {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                MethodRow(
                    icon: "photo",
                    title: "Photo from Library",
                    subtitle: "Screenshot or recipe card. Single image.",
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)
            .accessibilityLabel("Photo from library")
            .accessibilityHint("Pick a recipe screenshot or photo for OCR import")

            Button { showPasteSheet = true } label: {
                MethodRow(
                    icon: "text.alignleft",
                    title: "Paste text",
                    subtitle: "From a screenshot OCR, email, or anywhere.",
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)
            .accessibilityLabel("Paste recipe text")
            .accessibilityHint("Opens a sheet where you can paste recipe text from any source")
        }
    }

    private var privacyNote: some View {
        Text("Anything you import stays private to your account. We don't train on your cookbook.")
            .font(.system(size: 12))
            .foregroundStyle(Color.Stir.ink500)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.Stir.paper100),
            )
    }

    // MARK: - Footer CTA

    private var footer: some View {
        Button {
            Task { await viewModel.submitURL(urlText) }
        } label: {
            HStack(spacing: 8) {
                if viewModel.isBusy {
                    ProgressView().tint(.white)
                }
                Text(viewModel.isBusy ? "Importing…" : "Import link")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(urlText.isEmpty || viewModel.isBusy ? Color.Stir.ink300 : Color.Stir.ember600),
            )
        }
        .disabled(urlText.isEmpty || viewModel.isBusy)
        .accessibilityLabel(viewModel.isBusy ? "Importing" : "Import link")
        .accessibilityHint(urlText.isEmpty ? "Enter a URL above to enable" : "Submits the URL for parsing")
        .accessibilityAddTraits(viewModel.isBusy ? [.updatesFrequently] : [])
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .background(Color.Stir.paper50.ignoresSafeArea(.all, edges: .bottom))
    }

    // MARK: - Photo pick → OCR

    private func handlePicked(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            return
        }
        await viewModel.submitScreenshot(image: image)
        pickerItem = nil
    }
}

// MARK: - Method row

private struct MethodRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.Stir.ember100)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.Stir.ember600)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.Stir.ink900)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Stir.ink500)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.Stir.ink500)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.Stir.ink100, lineWidth: 1),
        )
    }
}

// MARK: - Paste sheet

private struct PasteSheet: View {
    @Binding var text: String
    let onSubmit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Paste recipe text")
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                        .tracking(-0.22)
                        .foregroundStyle(Color.Stir.ink900)
                    Text("From anywhere — email, an OCR app, a friend's text.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Stir.ink500)
                    TextEditor(text: $text)
                        .font(.system(size: 14))
                        .frame(minHeight: 280)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.Stir.paper100),
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.Stir.ink100, lineWidth: 1),
                        )
                }
                .padding(20)
            }
            .background(Color.Stir.paper50.ignoresSafeArea())
            .navigationTitle("Paste recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.Stir.ink700)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: onSubmit)
                        .foregroundStyle(text.isEmpty ? Color.Stir.ink300 : Color.Stir.ember600)
                        .disabled(text.isEmpty)
                }
            }
        }
    }
}
