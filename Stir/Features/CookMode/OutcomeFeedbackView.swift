// OutcomeFeedbackView
//
// End-of-cook feedback sheet. 5-star rating is required; the rest is
// optional. Spec §4.15 structured taxonomy — workload / taste /
// spiceLevel / wouldRepeat / leftoverCount — feeds step-7's
// preference-memory loop.
//
// Presented from CookModeRoot as a fullScreenCover after the user
// taps Finish on the last step. On submit, writes via
// OutcomeFeedbackRepository.upsert and calls back to the host which
// dismisses Cook Mode.

import OSLog
import SwiftUI

struct OutcomeFeedbackView: View {
    let session: CookingSession
    let onSubmitted: () -> Void

    @State private var rating: Int = 0
    @State private var workload: OutcomeFeedback.Workload = .medium
    @State private var taste: OutcomeFeedback.Taste = .good
    @State private var spiceLevel: OutcomeFeedback.SpiceLevel = .medium
    @State private var wouldRepeat: Bool = false
    @State private var notes: String = ""
    @State private var leftoverCount: Int = 0
    @State private var submitting: Bool = false
    @State private var submitError: String?

    private let repository: OutcomeFeedbackRepository
    private let analytics: PostHogClient

    init(
        session: CookingSession,
        onSubmitted: @escaping () -> Void,
        repository: OutcomeFeedbackRepository = OutcomeFeedbackRepository(),
        analytics: PostHogClient = .shared,
    ) {
        self.session = session
        self.onSubmitted = onSubmitted
        self.repository = repository
        self.analytics = analytics
    }

    var body: some View {
        NavigationStack {
            Form {
                ratingSection
                workloadSection
                tasteSection
                spiceSection
                repeatSection
                leftoversSection
                notesSection
                if let submitError {
                    Section {
                        Text(submitError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Rate this meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip", action: skipAndDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitting ? "Saving…" : "Save") {
                        Task { await submit() }
                    }
                    .disabled(rating == 0 || submitting)
                }
            }
        }
    }

    // MARK: - Sections

    private var ratingSection: some View {
        Section("How'd it turn out?") {
            HStack(spacing: 12) {
                ForEach(1...5, id: \.self) { index in
                    Button {
                        rating = index
                    } label: {
                        Image(systemName: index <= rating ? "star.fill" : "star")
                            .font(.title2)
                            .foregroundStyle(index <= rating ? .yellow : .secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(index) star\(index == 1 ? "" : "s")")
                    .accessibilityAddTraits(index <= rating ? .isSelected : [])
                    .accessibilityHint("Rate this meal \(index) out of 5")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(rating == 0 ? "Rating, not set" : "Rating, \(rating) out of 5")
        }
    }

    private var workloadSection: some View {
        Section("Workload") {
            Picker("Effort", selection: $workload) {
                Text("Easy").tag(OutcomeFeedback.Workload.easy)
                Text("Medium").tag(OutcomeFeedback.Workload.medium)
                Text("Hard").tag(OutcomeFeedback.Workload.hard)
            }
            .pickerStyle(.segmented)
        }
    }

    private var tasteSection: some View {
        Section("Taste") {
            Picker("Flavor", selection: $taste) {
                Text("Loved").tag(OutcomeFeedback.Taste.loved)
                Text("Good").tag(OutcomeFeedback.Taste.good)
                Text("OK").tag(OutcomeFeedback.Taste.ok)
                Text("Bad").tag(OutcomeFeedback.Taste.bad)
            }
            .pickerStyle(.segmented)
        }
    }

    private var spiceSection: some View {
        Section("Spice level") {
            Picker("Spice", selection: $spiceLevel) {
                Text("Mild").tag(OutcomeFeedback.SpiceLevel.mild)
                Text("Medium").tag(OutcomeFeedback.SpiceLevel.medium)
                Text("Hot").tag(OutcomeFeedback.SpiceLevel.hot)
                Text("Too hot").tag(OutcomeFeedback.SpiceLevel.tooHot)
            }
            .pickerStyle(.segmented)
        }
    }

    private var repeatSection: some View {
        Section {
            Toggle("Cook this again", isOn: $wouldRepeat)
        }
    }

    private var leftoversSection: some View {
        Section("Leftover servings") {
            Stepper(
                value: $leftoverCount,
                in: 0...12,
            ) {
                Text("\(leftoverCount) serving\(leftoverCount == 1 ? "" : "s")")
            }
        }
    }

    private var notesSection: some View {
        Section("Anything else?") {
            TextField(
                "e.g. needed more salt, would halve the pepper",
                text: $notes,
                axis: .vertical,
            )
            .textInputAutocapitalization(.sentences)
            .lineLimit(2...4)
        }
    }

    // MARK: - Actions

    private func submit() async {
        guard rating > 0, !submitting else { return }
        submitting = true
        submitError = nil
        do {
            try repository.upsert(for: session, input: OutcomeFeedbackRepository.Input(
                rating: rating,
                workload: workload,
                taste: taste,
                spiceLevel: spiceLevel,
                wouldRepeat: wouldRepeat,
                notes: notes.isEmpty ? nil : notes,
                leftoverCount: leftoverCount,
            ))
            analytics.capture(.mealRated, properties: [
                "rating": rating,
                "has_notes": !notes.isEmpty,
                "issues_count": 0,  // spec §15 field; step-7 adds an issues picker
                "workload": workload.rawValue,
                "taste": taste.rawValue,
                "spice_level": spiceLevel.rawValue,
                "would_repeat": wouldRepeat,
                "leftover_count": leftoverCount,
            ])
            submitting = false
            onSubmitted()
        } catch {
            Logger.coreData.error("outcome feedback save failed: \(error.localizedDescription, privacy: .public)")
            submitError = "We couldn't save your feedback. Try again or tap Skip."
            submitting = false
        }
    }

    /// Skip without rating — still count as completing the session, but
    /// don't fire meal_rated. User can still see the meal in Saved.
    private func skipAndDismiss() {
        onSubmitted()
    }
}
