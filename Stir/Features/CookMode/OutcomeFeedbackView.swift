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
    /// What the host should do next after the sheet completes. SCA-55:
    /// the host (CookModeRoot) routes Premium+ users with logged
    /// leftovers into LeftoversRoot, Free users to the leftovers-gate
    /// paywall, and everyone else (including skip) straight to dismiss.
    /// Living on the View itself rather than in a feature/coordinator
    /// type keeps the call surface narrow — only the host that already
    /// embeds OutcomeFeedbackView needs to switch on it.
    enum PostSubmitIntent: Equatable {
        case dismiss
        case openLeftovers
        case openPaywall(PaywallTrigger)
        /// SCA-66: rating ≥ 4 on an un-saved recipe → surface the
        /// "Save as a one-tap weeknight meal?" card. Always tier-
        /// agnostic; the card itself routes Premium+ to a direct save
        /// and Free to `PaywallTrigger.savedFavoritesGate`.
        case suggestSave(recipePlanId: UUID)
    }

    let session: CookingSession
    let onSubmitted: (PostSubmitIntent) -> Void

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
    /// Injected so `submit()` can decide between `.openLeftovers`,
    /// `.openPaywall(.leftoversGate)`, and `.dismiss` based on the
    /// effective tier. Optional with a server-only fallback so unit
    /// tests can omit it without losing coverage of the leftoverCount=0
    /// dismiss path. When nil, leftoverCount>0 trips `.dismiss` rather
    /// than `.openLeftovers` — server-side ENT-LEFTOVERS-01 remains the
    /// authoritative gate.
    private let entitlements: EntitlementService?

    init(
        session: CookingSession,
        onSubmitted: @escaping (PostSubmitIntent) -> Void,
        repository: OutcomeFeedbackRepository = OutcomeFeedbackRepository(),
        analytics: PostHogClient = .shared,
        entitlements: EntitlementService? = nil,
    ) {
        self.session = session
        self.onSubmitted = onSubmitted
        self.repository = repository
        self.analytics = analytics
        self.entitlements = entitlements
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
            // SCA-126: pass `.shared` explicitly. Was a default-arg
            // before; the SCA-56 CR1 S8 finding called out the same
            // pattern as a fragile test seam.
            let intent = Self.postSubmitIntent(
                leftoverCount: leftoverCount,
                rating: rating,
                recipePlan: session.recipePlan,
                entitlements: entitlements,
                repeatCandidateSuppression: .shared,
            )
            analytics.capture(.mealRated, properties: [
                "rating": rating,
                "has_notes": !notes.isEmpty,
                "issues_count": 0,  // spec §15 field; step-7 adds an issues picker
                "workload": workload.rawValue,
                "taste": taste.rawValue,
                "spice_level": spiceLevel.rawValue,
                "would_repeat": wouldRepeat,
                "leftover_count": leftoverCount,
                // SCA-55: leftover-handoff funnel properties. _offered is
                // true when the user logged leftovers AND the gate routed
                // them either into Leftovers (Premium+) or the paywall
                // (Free). _taken is reserved for the Premium+ branch — the
                // Free→paywall path emits its own `paywall_viewed.trigger=
                // leftovers_gate` event. _eligible_free sizes the
                // conversion opportunity.
                //
                // SCA-56 critical fix: read `effectiveTier`, NOT raw
                // `tier`, for `_eligible_free`. The gate decision uses
                // `effectiveTier` (which demotes (.premium|.pro,
                // .expired|.none) to .free per EntitlementService:176-181),
                // so reading raw `tier` here under-reports the Free-
                // equivalent cohort the property is meant to size.
                "leftovers_handoff_offered": intent != .dismiss,
                "leftovers_handoff_taken": intent == .openLeftovers,
                "leftovers_eligible_free": leftoverCount > 0
                    && (entitlements?.effectiveTier == .free),
            ])
            // SCA-65: schedule the +20h leftovers followup notification
            // when the user logged leftovers AND is Premium+. Free users
            // never schedule (they can't act on it without upgrading;
            // the paywall conversion event already fires via the gate
            // above). The scheduler internally handles cap / suppression
            // / authorization fallback — this is just the trigger.
            if leftoverCount > 0,
               let tier = entitlements?.effectiveTier,
               tier == .premium || tier == .pro {
                Task { @MainActor in
                    await LeftoversFollowupScheduler.shared.scheduleAfterFeedback(
                        submittedAt: .init(),
                        tier: tier,
                    )
                }
            }
            submitting = false
            onSubmitted(intent)
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
                    "recipe_plan_id": session.recipePlan?.id?.uuidString ?? "unknown",
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
    ///
    /// SCA-55: skip ALWAYS routes to `.dismiss` regardless of any
    /// (un-saved) leftoverCount stepper value — the user opted out of
    /// rating, so we shouldn't pivot them into a Premium-feature pitch
    /// they didn't ask for.
    private func skipAndDismiss() {
        analytics.capture(.mealRatingSkipped, properties: [
            "recipe_plan_id": session.recipePlan?.id?.uuidString ?? "unknown",
        ])
        onSubmitted(.dismiss)
    }

    /// Decide which intent to bubble up after a successful submit.
    ///
    /// Decision priority (top wins; mutually exclusive at exit):
    ///   1. `leftoverCount > 0` → leftovers handoff (Premium+) OR
    ///      leftovers-gate paywall (Free). SCA-55 D2 — don't defer.
    ///   2. `rating ≥ 4` on a not-yet-favorited recipe (gate on
    ///      `isFavorite`, NOT `isSaved` — SCA-109) AND not in the
    ///      per-recipe suppression set → suggestSave card. SCA-66.
    ///   3. Else → dismiss.
    ///
    /// Pulled out so unit tests can assert the intent matrix without
    /// driving the full submit path through Core Data. `internal` (not
    /// `private`) because `OutcomeFeedbackViewIntentTests` exercises
    /// it directly via @testable import — driving `submit()`
    /// end-to-end would require a full Core Data fixture per case for
    /// a small decision function.
    ///
    /// SCA-126: `repeatCandidateSuppression` is now REQUIRED — no
    /// default value. The prior `= .shared` default repeated the
    /// SCA-56 CR1 S8 antipattern: production hit `.shared`, tests
    /// injected a fresh suite, and the default-arg branch was never
    /// validated against the test path. Production callsite at
    /// `submit()` passes `.shared` explicitly; tests inject their own.
    @MainActor
    static func postSubmitIntent(
        leftoverCount: Int,
        rating: Int,
        recipePlan: RecipePlan?,
        entitlements: EntitlementService?,
        repeatCandidateSuppression: RepeatCandidateSuppressionStore,
    ) -> PostSubmitIntent {
        // 1. Leftovers handoff wins when present — single tap to next
        //    meal is more actionable than a save prompt.
        if leftoverCount > 0 {
            guard let entitlements else {
                // SCA-56 (CR1 S7): defensive fallback — production always
                // passes a non-nil EntitlementService via the host's init.
                // This branch exists for tests that don't care about the
                // gate; server-side ENT-LEFTOVERS-01 remains authoritative.
                return .dismiss
            }
            switch entitlements.canAccess(.leftoversMode) {
            case .allowed:
                return .openLeftovers
            case .blockedByTier, .blockedByBilling, .blockedByQuota:
                // SCA-56 (CR1 W1): collapsed the previously-dead
                // `.blockedByQuota` arm into the paywall path.
                return .openPaywall(.leftoversGate)
            }
        }

        // 2. SCA-66: rating ≥ 4 on a NOT-yet-favorited recipe → suggest save.
        //    Per-recipePlanId suppression honored ("never nag again for
        //    same recipe" per spec §8 row 947 fallback).
        //
        //    SCA-109 fix: gate on `isFavorite`, NOT `isSaved`. Per
        //    CLAUDE.md "Save for later = isFavorite — Tonight and Saved
        //    Share the Same Bit". `CookingSessionRepository.markCompleted`
        //    flips `isSaved=true` synchronously BEFORE
        //    `finishPresentationRequested` is set, so by the time submit()
        //    runs and reads the recipe state, `isSaved` is always true.
        //    The pre-fix gate was dead code in production: SCA-66 unit
        //    tests passed because they construct a fresh RecipePlan that
        //    never goes through markCompleted, but real cook flows never
        //    saw the suggestSave card. `isFavorite` is set ONLY by
        //    explicit `SolveRepository.setFavorite`, matching the intent
        //    "user hasn't favorited yet."
        if rating >= 4,
           let plan = recipePlan,
           plan.isFavorite == false,
           let planId = plan.id,
           !repeatCandidateSuppression.isSuppressed(recipePlanId: planId) {
            return .suggestSave(recipePlanId: planId)
        }

        return .dismiss
    }
}

