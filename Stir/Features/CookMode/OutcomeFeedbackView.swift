// OutcomeFeedbackView
//
// End-of-cook feedback sheet. 5-star rating is required; the rest is
// optional. Spec §4.15 structured taxonomy — workload / taste /
// spiceLevel / wouldRepeat / leftoverCount — feeds step-7's
// preference-memory loop.
//
// Presented from CookModeRoot as a fullScreenCover after the user taps
// Finish on the last step. On submit, writes via
// OutcomeFeedbackRepository.upsert and calls back to the host which
// dismisses Cook Mode.
//
// Redesigned 2026-05-03 from iOS `Form` onto the custom Stir DS.
// Pre-redesign issues (see attached screenshot in the redesign request):
//   - `Form` inherits the dark grouped-list grey panels in dark mode,
//     which drift hard from `paper50` + `stirCard` grammar used across
//     `SettingsRootView` / `HouseholdPreferencesView` / Cook Mode.
//   - Star row was skewed left because Form sections use a leading-
//     aligned content gutter — the row needs to be centered in its own
//     stirCard.
// Data captured is unchanged — every field is load-bearing for step-7.
// Only the visual layer moved to tokens.

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
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                    headerSection
                    ratingSection
                    workloadSection
                    tasteSection
                    spiceSection
                    repeatSection
                    leftoversSection
                    notesSection
                    if let submitError {
                        errorBanner(submitError)
                    }
                }
                .padding(.horizontal, CGFloat.Stir.screenMargin)
                .padding(.top, CGFloat.Stir.space3)
                .padding(.bottom, CGFloat.Stir.space3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.Stir.paper50)
            // .safeAreaInset is the right primitive here — it auto-insets
            // the ScrollView content (no magic-number padding to drift
            // against the bar's true height), reports the bar as part of
            // the safe area so SwiftUI's cursor auto-scroll keeps the
            // notes TextField visible above it, and slides up cleanly
            // with the keyboard. The ZStack-bottom + manual-padding
            // pattern misses all three.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionBar
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Rate this meal")
                        .stirFont(.displaySm)
                        .foregroundStyle(Color.Stir.textPrimary)
                }
            }
            .toolbarBackground(Color.Stir.paper50, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            Text("Tonight · Cooked")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.ember600)
            Text(headerTitle)
                .stirFont(.displayLg)
                .foregroundStyle(Color.Stir.ink900)
                .fixedSize(horizontal: false, vertical: true)
            Text("One tap. I'll learn for next time.")
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink500)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerTitle: String {
        if let title = session.recipePlan?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return "How was the \(title)?"
        }
        return "How'd it turn out?"
    }

    private var ratingSection: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            sectionEyebrow("Your rating")
            HStack(spacing: CGFloat.Stir.space3) {
                ForEach(1...5, id: \.self) { index in
                    Button {
                        rating = index
                    } label: {
                        Image(systemName: index <= rating ? "star.fill" : "star")
                            .font(.system(size: 30, weight: .regular)) // justification: 30pt scale gives a centered hero star row inside the rating card; 24pt looked undersized in stirCard
                            .foregroundStyle(index <= rating ? Color.Stir.ember600 : Color.Stir.ink300)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(index) star\(index == 1 ? "" : "s")")
                    .accessibilityAddTraits(index <= rating ? .isSelected : [])
                    .accessibilityHint("Rate this meal \(index) out of 5")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, CGFloat.Stir.space4)
            .stirCard()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(rating == 0 ? "Rating, not set" : "Rating, \(rating) out of 5")
        }
    }

    private var workloadSection: some View {
        chipSection(
            label: "Workload",
            options: OutcomeFeedback.Workload.allCases,
            selection: workload,
            display: workloadLabel,
            onSelect: { workload = $0 },
        )
    }

    private var tasteSection: some View {
        chipSection(
            label: "Taste",
            options: OutcomeFeedback.Taste.allCases,
            selection: taste,
            display: tasteLabel,
            onSelect: { taste = $0 },
        )
    }

    private var spiceSection: some View {
        chipSection(
            label: "Spice level",
            options: OutcomeFeedback.SpiceLevel.allCases,
            selection: spiceLevel,
            display: spiceLabel,
            onSelect: { spiceLevel = $0 },
        )
    }

    private var repeatSection: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            sectionEyebrow("Cook this again")
            HStack(spacing: CGFloat.Stir.space3) {
                Text(wouldRepeat ? "Yes — I'd cook this again" : "Maybe next time")
                    .stirFont(.labelLg)
                    .foregroundStyle(Color.Stir.textPrimary)
                Spacer(minLength: CGFloat.Stir.space2)
                Toggle("", isOn: $wouldRepeat)
                    .labelsHidden()
                    .tint(Color.Stir.ember600)
                    .accessibilityLabel("Cook this again")
            }
            .padding(.horizontal, CGFloat.Stir.space3Half)
            .padding(.vertical, CGFloat.Stir.space3Half)
            .stirCard()
        }
    }

    private var leftoversSection: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            sectionEyebrow("Leftover servings")
            HStack(spacing: CGFloat.Stir.space3) {
                Text("\(leftoverCount) serving\(leftoverCount == 1 ? "" : "s")")
                    .stirFont(.labelLg)
                    .foregroundStyle(Color.Stir.textPrimary)
                Spacer(minLength: CGFloat.Stir.space2)
                Stepper("", value: $leftoverCount, in: 0...12)
                    .labelsHidden()
                    .accessibilityLabel("Leftover servings")
                    .accessibilityValue("\(leftoverCount) serving\(leftoverCount == 1 ? "" : "s")")
            }
            .padding(.horizontal, CGFloat.Stir.space3Half)
            .padding(.vertical, CGFloat.Stir.space3Half)
            .stirCard()
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            sectionEyebrow("Anything else?")
            TextField(
                "e.g. needed more salt, would halve the pepper",
                text: $notes,
                axis: .vertical,
            )
            .stirFont(.bodyMd)
            .foregroundStyle(Color.Stir.ink900)
            .textInputAutocapitalization(.sentences)
            .lineLimit(2...4)
            .padding(.horizontal, CGFloat.Stir.space3Half)
            .padding(.vertical, CGFloat.Stir.space3Half)
            .stirCard()
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: CGFloat.Stir.space2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.Stir.crimson600)
                .accessibilityHidden(true)
            Text(message)
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.crimson600)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, CGFloat.Stir.space3Half)
        .padding(.vertical, CGFloat.Stir.space3)
        .stirCard(
            fill: Color.Stir.crimson100,
            borderColor: Color.Stir.crimson600.opacity(0.3),
        )
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.Stir.divider)
                .frame(height: 1)
            HStack(spacing: CGFloat.Stir.space3) {
                SecondaryButton(title: "Skip", action: skipAndDismiss)
                PrimaryButton(
                    title: submitting ? "Saving…" : "Save",
                    isBusy: submitting,
                    isDisabled: rating == 0,
                    action: { Task { await submit() } },
                )
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.top, CGFloat.Stir.space3)
            .padding(.bottom, CGFloat.Stir.space3)
        }
        .background(Color.Stir.paper50)
    }

    // MARK: - Helpers

    private func sectionEyebrow(_ text: String) -> some View {
        Text(text)
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.ink500)
    }

    /// Horizontal chip row replacing the iOS segmented `Picker` — same
    /// grammar as `SetupPreferencesView` / `ConstraintsSheet` so the
    /// Cook-Mode-trailing surface reads continuously with the rest of
    /// the app.
    @ViewBuilder
    private func chipSection<Option: Hashable>(
        label: String,
        options: [Option],
        selection: Option,
        display: @escaping (Option) -> String,
        onSelect: @escaping (Option) -> Void,
    ) -> some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            sectionEyebrow(label)
            HStack(spacing: CGFloat.Stir.space2) {
                ForEach(options, id: \.self) { option in
                    SelectableChip(
                        label: display(option),
                        tone: .accent,
                        isSelected: option == selection,
                        action: { onSelect(option) },
                    )
                }
            }
        }
    }

    private func workloadLabel(_ value: OutcomeFeedback.Workload) -> String {
        switch value {
        case .easy:   return "Easy"
        case .medium: return "Medium"
        case .hard:   return "Hard"
        }
    }

    private func tasteLabel(_ value: OutcomeFeedback.Taste) -> String {
        switch value {
        case .loved: return "Loved"
        case .good:  return "Good"
        case .ok:    return "OK"
        case .bad:   return "Bad"
        }
    }

    private func spiceLabel(_ value: OutcomeFeedback.SpiceLevel) -> String {
        switch value {
        case .mild:   return "Mild"
        case .medium: return "Medium"
        case .hot:    return "Hot"
        case .tooHot: return "Too hot"
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
            // Match HouseholdPreferencesView's pattern — repository
            // failures are real user-facing data loss and need prod
            // observability beyond OSLog. The user-visible string still
            // routes through `submitError` for the in-screen banner.
            SentryReporter.shared.captureError(
                error,
                context: [
                    "screen": "outcome_feedback",
                    "rating": String(rating),
                    "recipe_plan_id": session.recipePlan?.id?.uuidString ?? "",
                ],
            )
            submitError = "We couldn't save your feedback. Try again or tap Skip."
            submitting = false
        }
    }

    /// Skip without rating — still count as completing the session, but
    /// don't fire meal_rated. Instead emit meal_rating_skipped so the
    /// north-star funnel can distinguish "user opted out of rating" from
    /// "user never reached the sheet." User can still see the meal in
    /// Saved.
    private func skipAndDismiss() {
        analytics.capture(.mealRatingSkipped, properties: [
            "recipe_plan_id": session.recipePlan?.id?.uuidString ?? "",
        ])
        onSubmitted()
    }
}

